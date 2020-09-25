#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#include <CoronaRuntime.h>
#import "Utils.h"

@interface PluginMicrophone : NSObject <AVCaptureAudioDataOutputSampleBufferDelegate>
@property (retain) AVAssetWriter *asset_writer;
@property (retain) AVAssetWriterInput *asset_writer_audio;
@property (retain) NSString *output_file_path;
@property (retain) NSDictionary *audio_settings;
@end

static NSString *const EVENT_NAME = @"microphone";
static NSString *const PHASE_KEY = @"phase";
static NSString *const IS_ERROR_KEY = @"is_error";
static NSString *const ERROR_CODE_KEY = @"error_code";
static NSString *const ERROR_MESSAGE_KEY = @"error_message";
static const int BITS_PER_SAMPLE = 16;

typedef NS_ENUM(NSInteger, ErrorCode) {
	ERROR_CODE_NO_ERROR,
	ERROR_CODE_ALREADY_INITIALIZED,
	ERROR_CODE_INIT_FAILED,
	ERROR_CODE_MISSING_MICROPHONE,
	ERROR_CODE_MISSING_PERMISSION,
	ERROR_CODE_DENIED_PERMISSION,
	ERROR_CODE_PERMISSION_REQUEST_FAILED,
	ERROR_CODE_FILE_OPEN_FAILED,
	ERROR_CODE_FILE_WRITE_FAILED,
	ERROR_CODE_EMPTY_RECORDING
};

@implementation PluginMicrophone {
	double detector_on, detector_off;
	double detector_volume;
	double gain, gain_min, gain_max, volume_target, gain_speed;
	bool allow_clipping;
	int sample_rate;
	bool is_initialized;
	bool is_recording;
	bool is_detector_on, is_detector_paused;
	int lua_listener;
	AVCaptureSession *capture_session;
	dispatch_queue_t audio_data_output_queue;
	CMSampleBufferRef sample_buffer_copy;
	CMTime start_timestamp, end_timestamp;
}

static PluginMicrophone *plugin;

static int on_enter_frame(lua_State *L) {return [plugin on_enter_frame:L];}
static int enable_debug(lua_State *L) {return [plugin enable_debug:L];}
static int init(lua_State *L) {return [plugin _init:L];}
static int start(lua_State *L) {return [plugin start:L];}
static int stop(lua_State *L) {return [plugin stop:L];}
static int is_recording_(lua_State *L) {return [plugin is_recording:L];}
static int get_volume(lua_State *L) {return [plugin get_volume:L];}
static int get_gain(lua_State *L) {return [plugin get_gain:L];}
static int set(lua_State *L) {return [plugin set:L];}

-(int)open:(lua_State*)L {
	const luaL_Reg lua_functions[] = {
		{"enableDebug", enable_debug},
		{"init", init},
		{"start", start},
		{"stop", stop},
		{"isRecording", is_recording_},
		{"getVolume", get_volume},
		{"getGain", get_gain},
		{"set", set},
		{NULL, NULL}
	};

	const char *plugin_name = lua_tostring(L, 1);
	luaL_openlib(L, plugin_name, lua_functions, 1);

	[Utils getDirPointers:L];
	[Utils setTag:@"plugin.microphone"];

	CoronaLuaPushRuntime(L);

	// Add enterFrame listener to always have a fresh Lua state for event dispatching.
	lua_getfield(L, -1, "addEventListener");
	CoronaLuaPushRuntime(L);
	lua_pushstring(L, "enterFrame");
	lua_pushcfunction(L, on_enter_frame);
	lua_call(L, 3, 0);

	lua_pop(L, 1); // pop Runtime

	detector_volume = 0;
	gain_min = 0;
	gain_max = 0;
	volume_target = 0;
	gain_speed = 0;
	gain = 1;
	is_initialized = false;
	is_recording = false;
	allow_clipping = false;
	lua_listener = LUA_REFNIL;

	sample_buffer_copy = nil;

	return 1;
}

-(bool)check_is_not_initialized {
	if (!is_initialized) {
		[Utils log:@"the plugin is not initialized"];
	}
	return !is_initialized;
}

-(NSString*)error_code_to_string:(ErrorCode)error_code {
	switch (error_code) {
		case ERROR_CODE_INIT_FAILED:
			return @"init_failed";
		case ERROR_CODE_ALREADY_INITIALIZED:
			return @"already_initialized";
		case ERROR_CODE_FILE_OPEN_FAILED:
			return @"file_open_failed";
		case ERROR_CODE_FILE_WRITE_FAILED:
			return @"file_write_failed";
		case ERROR_CODE_EMPTY_RECORDING:
			return @"empty_recording";
		case ERROR_CODE_MISSING_MICROPHONE:
			return @"missing_microphone";
		default:
			return @"";
	}
}

# pragma mark - Lua functions -

-(int)on_enter_frame:(lua_State*)L {
	[Utils executeTasks:L];
	return 0;
}

-(int)enable_debug:(lua_State*)L {
	[Utils checkArgCount:L count:0];
	[Utils enableDebug];
	return 0;
}

-(int)_init:(lua_State*)L {
	[Utils checkArgCount:L count:1];

	Scheme *scheme = [[Scheme alloc] init];
	[scheme string:@"filename"];
	[scheme lightuserdata:@"baseDir"];
	[scheme table:@"detector"];
	[scheme number:@"detector.on"];
	[scheme number:@"detector.off"];
	[scheme number:@"sampleRate"];
	[scheme table:@"gain"];
	[scheme number:@"gain.min"];
	[scheme number:@"gain.max"];
	[scheme number:@"gain.value"];
	[scheme number:@"gain.target"];
	[scheme number:@"gain.speed"];
	[scheme boolean:@"gain.allowClipping"];
	[scheme listener:@"listener"];

	ErrorCode error_code = ERROR_CODE_NO_ERROR;
	bool is_error = false;
	NSString *error_message;
	NSError *error = nil;

	Table *params = [[Table alloc] init:L index:1];
	[params parse:scheme];
	lua_listener = [[params getListener:@"listener"] intValue];

	if (![self check_is_not_initialized]) {
		is_error = true;
		error_code = ERROR_CODE_ALREADY_INITIALIZED;
		error_message = @"Already initialized";
	}

	if (!is_error) {
		NSString *filename = [params getString:@"filename"];
		LuaLightuserdata *base_dir = [params getLightuserdata:@"baseDir" default:[Utils getDocumentsDirectory]];
		detector_on = [params getDouble:@"detector.on" default:0];
		detector_off = [params getDouble:@"detector.off" default:0];
		sample_rate = [params getInteger:@"sampleRate" default:44100];
		gain_min = [params getDouble:@"gain.min" default:0];
		gain_max = [params getDouble:@"gain.max" default:MAXFLOAT];
		gain = [params getDouble:@"gain.value" default:1.0];
		volume_target = [params getDouble:@"gain.target" default:0];
		gain_speed = [params getDouble:@"gain.speed" default:0.1];
		allow_clipping = [params getDouble:@"gain.allowClipping" default:false];

		gain_min = [Utils clampDouble:gain_min min:0 max:MAXFLOAT];
		gain_max = [Utils clampDouble:gain_max min:0 max:MAXFLOAT];
		volume_target = [Utils clampDouble:volume_target min:0 max:1];
		gain_speed = [Utils clampDouble:gain_speed min:0 max:1];
		gain = [Utils clampDouble:gain min:gain_min max:gain_max];

		detector_volume = 0;
		is_detector_on = false;
		is_detector_paused = false;

		self.audio_settings = @{
			AVFormatIDKey : @(kAudioFormatLinearPCM),
			AVNumberOfChannelsKey : @(1),
			AVSampleRateKey : @(sample_rate),
			AVLinearPCMBitDepthKey : @(BITS_PER_SAMPLE),
			AVLinearPCMIsNonInterleaved : @NO,
			AVLinearPCMIsFloatKey : @NO,
			AVLinearPCMIsBigEndianKey : @NO
		};

		self.output_file_path = [NSString stringWithString:[Utils pathForFile:L filename:filename baseDir:[Utils baseDirToString:base_dir]]];
		[[NSFileManager defaultManager] removeItemAtPath:self.output_file_path error:nil];
		self.asset_writer = [AVAssetWriter assetWriterWithURL:[NSURL fileURLWithPath:self.output_file_path] fileType:AVFileTypeWAVE error:&error];
		if (error) {
			is_error = true;
			error_code = ERROR_CODE_FILE_OPEN_FAILED;
			error_message = [NSString stringWithFormat:@"File %@ can't be opened for writing.", self.output_file_path];
		}
	}

	if (!is_error) {
		self.asset_writer_audio = [[AVAssetWriterInput alloc] initWithMediaType:AVMediaTypeAudio outputSettings:self.audio_settings];
		if (!self.asset_writer_audio) {
			is_error = true;
			error_code = ERROR_CODE_INIT_FAILED;
			error_message = @"Incompatible audio encoding settings.";
		} else {
			self.asset_writer_audio.expectsMediaDataInRealTime = YES;
			if ([self.asset_writer canAddInput:self.asset_writer_audio]) {
				[self.asset_writer addInput:self.asset_writer_audio];
			} else {
				is_error = true;
				error_code = ERROR_CODE_INIT_FAILED;
				error_message = self.asset_writer.error.localizedDescription;
			}
		}
	}

	AVCaptureDevice *audio_device = nil;
	if (!is_error) {
		audio_device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeAudio];
		if (!audio_device || !audio_device.connected) {
			is_error = true;
			error_code = ERROR_CODE_MISSING_MICROPHONE;
			error_message = @"Device does not have a microphone.";
		}
	}

	if (!is_error) {
		capture_session = [[AVCaptureSession alloc] init];
	}

	AVCaptureDeviceInput *capture_audio_device_input = nil;
	if (!is_error) {
		capture_audio_device_input = [AVCaptureDeviceInput deviceInputWithDevice:audio_device error:&error];
		if (error) {
			is_error = true;
			error_code = ERROR_CODE_INIT_FAILED;
			error_message = error.localizedDescription;
		}
	}

	if (!is_error) {
		if ([capture_session canAddInput:capture_audio_device_input]) {
			[capture_session addInput:capture_audio_device_input];
		} else {
			is_error = true;
			error_code = ERROR_CODE_INIT_FAILED;
			error_message = @"Could not addInput to capture_session.";
		}
	}

	if (!is_error) {
		AVCaptureAudioDataOutput *capture_audio_data_output = [[AVCaptureAudioDataOutput alloc] init];
		audio_data_output_queue = dispatch_queue_create("AudioDataOutputQueue", DISPATCH_QUEUE_SERIAL);
		[capture_audio_data_output setSampleBufferDelegate:self queue:audio_data_output_queue];
		dispatch_release(audio_data_output_queue);

		if ([capture_session canAddOutput:capture_audio_data_output]) {
			[capture_session addOutput:capture_audio_data_output];
		} else {
			is_error = true;
			error_code = ERROR_CODE_INIT_FAILED;
			error_message = @"Could not addOutput to capture_session.";
		}
	}

	if (error_code != ERROR_CODE_ALREADY_INITIALIZED) {
		is_initialized = !is_error;
	}

	NSMutableDictionary *event = [Utils newEvent:EVENT_NAME];
	event[PHASE_KEY] = @"init";
	event[IS_ERROR_KEY] = @(is_error);
	if (is_error) {
		event[ERROR_CODE_KEY] = [self error_code_to_string:error_code];
		event[ERROR_MESSAGE_KEY] = error_message;
	}
	[Utils dispatchEvent:lua_listener event:event];

	return 0;
}

-(int)start:(lua_State*)L {
	[Utils checkArgCount:L count:0];
	if ([self check_is_not_initialized] || is_recording) {
		return 0;
	}
	[capture_session startRunning];
	is_recording = true;
	return 0;
}

-(int)stop:(lua_State*)L {
	[Utils checkArgCount:L count:0];
	if ([self check_is_not_initialized] || !is_recording) {
		return 0;
	}
	[capture_session stopRunning];
	[self.asset_writer_audio markAsFinished];
	[self.asset_writer finishWritingWithCompletionHandler:^{
		self.asset_writer_audio = nil;
		self.asset_writer = nil;
		audio_data_output_queue = nil;
		detector_volume = 0;
		is_recording = false;
		is_initialized = false;

		if (is_detector_on) {
			if (is_detector_paused) {
				[self trim_file];
			} else {
				NSMutableDictionary *event = [Utils newEvent:EVENT_NAME];
				event[PHASE_KEY] = @"recorded";
				event[IS_ERROR_KEY] = @((bool)false);
				[Utils dispatchEvent:lua_listener event:event];
			}
		} else {
			NSMutableDictionary *event = [Utils newEvent:EVENT_NAME];
			event[PHASE_KEY] = @"recorded";
			event[IS_ERROR_KEY] = @((bool)true);
			event[ERROR_CODE_KEY] = [self error_code_to_string:ERROR_CODE_EMPTY_RECORDING];
			event[ERROR_MESSAGE_KEY] = @"The recording is empty.";
			[Utils dispatchEvent:lua_listener event:event];
		}
	}];
	return 0;
}

-(int)is_recording:(lua_State*)L {
	[Utils checkArgCount:L count:0];
	lua_pushboolean(L, is_recording);
	return 1;
}

-(int)get_volume:(lua_State*)L {
	[Utils checkArgCount:L count:0];
	lua_pushnumber(L, detector_volume);
	return 1;
}

-(int)get_gain:(lua_State*)L {
	[Utils checkArgCount:L count:0];
	lua_pushnumber(L, gain);
	return 1;
}

-(int)set:(lua_State*)L {
	[Utils checkArgCount:L count:1];

	Scheme *scheme = [[Scheme alloc] init];
	[scheme table:@"detector"];
	[scheme number:@"detector.on"];
	[scheme number:@"detector.off"];
	[scheme table:@"gain"];
	[scheme number:@"gain.min"];
	[scheme number:@"gain.max"];
	[scheme number:@"gain.value"];
	[scheme number:@"gain.target"];
	[scheme number:@"gain.speed"];
	[scheme boolean:@"gain.allowClipping"];

	Table *params = [[Table alloc] init:L index:1];
	[params parse:scheme];

	detector_on = [params getDouble:@"detector.on" default:detector_on];
	detector_off = [params getDouble:@"detector.off" default:detector_off];
	gain_min = [params getDouble:@"gain.min" default:gain_min];
	gain_max = [params getDouble:@"gain.max" default:gain_max];
	gain = [params getDouble:@"gain.value" default:gain];
	volume_target = [params getDouble:@"gain.target" default:volume_target];
	gain_speed = [params getDouble:@"gain.speed" default:gain_speed];
	allow_clipping = [params getDouble:@"gain.allowClipping" default:allow_clipping];

	gain_min = [Utils clampDouble:gain_min min:0 max:MAXFLOAT];
	gain_max = [Utils clampDouble:gain_max min:0 max:MAXFLOAT];
	volume_target = [Utils clampDouble:volume_target min:0 max:1];
	gain_speed = [Utils clampDouble:gain_speed min:0 max:1];
	gain = [Utils clampDouble:gain min:gain_min max:gain_max];
	return 0;
}

-(void)trim_file {
	NSError *error = nil;
	AVAsset *input_asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:self.output_file_path] options:nil];
	AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:input_asset error:nil];
	reader.timeRange = CMTimeRangeFromTimeToTime(kCMTimeZero, CMTimeAdd(CMTimeSubtract(end_timestamp, start_timestamp), CMTimeMake(200, 1000)));
	AVAssetReaderTrackOutput *reader_output = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:[[input_asset tracksWithMediaType:AVMediaTypeAudio] objectAtIndex:0]
																						outputSettings:@{AVFormatIDKey : [NSNumber numberWithInt:kAudioFormatLinearPCM]}];
	[reader addOutput:reader_output];
	[reader startReading];

	NSString *trim_file_path = [self.output_file_path stringByReplacingOccurrencesOfString:@".wav" withString:@"_trim.wav"];
	[[NSFileManager defaultManager] removeItemAtPath:trim_file_path error:nil];
	AVAssetWriter *writer = [AVAssetWriter assetWriterWithURL:[NSURL fileURLWithPath:trim_file_path] fileType:AVFileTypeWAVE error:&error];
	if (!error) {
		AVAssetWriterInput *writer_audio = [[AVAssetWriterInput alloc] initWithMediaType:AVMediaTypeAudio outputSettings:self.audio_settings];
		[writer addInput:writer_audio];
		[writer startWriting];
		__block bool is_started = false;
		dispatch_queue_t writing_queue = dispatch_queue_create("AudioTrimQueue", DISPATCH_QUEUE_SERIAL);
		[writer_audio requestMediaDataWhenReadyOnQueue:writing_queue usingBlock:^{
			CMSampleBufferRef sample_buffer = [reader_output copyNextSampleBuffer];
			if (sample_buffer) {
				if (!is_started) {
					[writer startSessionAtSourceTime:CMSampleBufferGetPresentationTimeStamp(sample_buffer)];
					is_started = true;
				}
				[writer_audio appendSampleBuffer:sample_buffer];
				CFRelease(sample_buffer);
			} else {
				[writer_audio markAsFinished];
				[writer finishWritingWithCompletionHandler:^{
					[[NSFileManager defaultManager] removeItemAtPath:self.output_file_path error:nil];
					NSError *error = nil;
					[[NSFileManager defaultManager] moveItemAtPath:trim_file_path toPath:self.output_file_path error:&error];
					NSMutableDictionary *event = [Utils newEvent:EVENT_NAME];
					event[PHASE_KEY] = @"recorded";
					if (error) {
						event[IS_ERROR_KEY] = @((bool)true);
						event[ERROR_CODE_KEY] = [self error_code_to_string:ERROR_CODE_FILE_WRITE_FAILED];
						event[ERROR_MESSAGE_KEY] = @"Failed to trim the file.";
					} else {
						event[IS_ERROR_KEY] = @((bool)false);
					}
					[Utils dispatchEvent:lua_listener event:event];
				}];
				dispatch_release(writing_queue);
			}
		}];
	} else {
		NSMutableDictionary *event = [Utils newEvent:EVENT_NAME];
		event[PHASE_KEY] = @"recorded";
		event[IS_ERROR_KEY] = @((bool)true);
		event[ERROR_CODE_KEY] = [self error_code_to_string:ERROR_CODE_FILE_WRITE_FAILED];
		event[ERROR_MESSAGE_KEY] = @"Failed to trim the file.";
		[Utils dispatchEvent:lua_listener event:event];
	}
}

#pragma mark - AVCaptureAudioDataOutputSampleBufferDelegate -
- (void)captureOutput:(AVCaptureOutput*)capture_output didOutputSampleBuffer:(CMSampleBufferRef)sample_buffer fromConnection:(AVCaptureConnection*)connection {
	if (CMSampleBufferDataIsReady(sample_buffer)) {
		if (is_recording) {
			if (self.asset_writer.status == AVAssetWriterStatusUnknown) {
				[self.asset_writer startWriting];
			}
			CMBlockBufferRef sample_data = CMSampleBufferGetDataBuffer(sample_buffer);
			size_t data_size = 0;
			char *data = NULL;
			CMBlockBufferGetDataPointer(sample_data, 0, NULL, &data_size, &data);

			if (volume_target > 0) {
				if (detector_volume > 0) {
					gain = gain + gain_speed * (volume_target - detector_volume);
					gain = [Utils clampDouble:gain min:gain_min max:gain_max];
				}
				double rms = 0;
				if (!allow_clipping) {
					int max_value = 0;
					for (int i = 0; i < data_size; i += 2) {
						short value = data[i] + (data[i + 1] << 8);
						if (value > max_value) {
							max_value = value;
						}
					}
					if (max_value * gain > 32768) {
						gain = 32768.0 / max_value;
					}
				}
				for (int i = 0; i < data_size; i += 2) {
					int value = data[i] + (data[i + 1] << 8);
					value *= gain;
					rms += pow(value / 32768.0, 2.0);
					data[i] = value & 0x00FF;
					data[i + 1] = value >> 8;
				}
				detector_volume = sqrt(rms / (data_size / 2));
			} else {
				double rms = 0;
				for (int i = 0; i < data_size; i += 2) {
					short value = data[i] + (data[i + 1] << 8);
					rms += pow(value / 32768.0, 2.0);
				}
				detector_volume = sqrt(rms / (data_size / 2));
			}
			if (is_detector_on || detector_volume >= detector_on) {
				if (!is_detector_on) {
					[Utils debugLog:@"Detector is ON."];
					is_detector_on = true;
					start_timestamp = CMSampleBufferGetPresentationTimeStamp(sample_buffer);
					[self.asset_writer startSessionAtSourceTime:start_timestamp];
				}
				// Write from memory.
				if (self.asset_writer_audio.isReadyForMoreMediaData && sample_buffer_copy != nil) {
					[self.asset_writer_audio appendSampleBuffer:sample_buffer_copy];
					CFRelease(sample_buffer_copy);
					sample_buffer_copy = nil;
				}
				if (self.asset_writer_audio.isReadyForMoreMediaData) {
					[self.asset_writer_audio appendSampleBuffer:sample_buffer];
				}
				if (detector_volume > detector_off) {
					if (is_detector_paused) {
						[Utils debugLog:@"Detector is RESUMED."];
						is_detector_paused = false;
					}
				} else {
					if (!is_detector_paused) {
						[Utils debugLog:@"Detector is PAUSED."];
						is_detector_paused = true;
						end_timestamp = CMSampleBufferGetPresentationTimeStamp(sample_buffer);
					}
				}
			} else {
				// Add one buffer to smooth OFF->ON transition.
				if (sample_buffer_copy != nil) {
					CFRelease(sample_buffer_copy);
					sample_buffer_copy = nil;
				}
				CMSampleBufferCreateCopy(kCFAllocatorDefault, sample_buffer, &sample_buffer_copy);
				CMBlockBufferRef sample_data = CMSampleBufferGetDataBuffer(sample_buffer);
				CMBlockBufferRef sample_data_copy = nil;
				CMBlockBufferCreateContiguous(kCFAllocatorDefault, sample_data, nil, nil, 0, CMBlockBufferGetDataLength(sample_data), kCMBlockBufferAlwaysCopyDataFlag, &sample_data_copy);
				CMSampleBufferSetDataBuffer(sample_buffer_copy, sample_data_copy);
			}
		}
	}
}

@end

CORONA_EXPORT int luaopen_plugin_microphone(lua_State *L);
CORONA_EXPORT int luaopen_plugin_microphone(lua_State *L) {
	plugin = [[PluginMicrophone alloc] init];
	return [plugin open:L];
}
