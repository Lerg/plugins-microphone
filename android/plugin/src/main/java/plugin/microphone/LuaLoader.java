package plugin.microphone;

import android.content.pm.PackageManager;
import android.media.AudioFormat;
import android.media.AudioRecord;
import android.media.MediaRecorder;
import android.os.Handler;
import android.os.HandlerThread;

import com.ansca.corona.CoronaActivity;
import com.ansca.corona.CoronaEnvironment;
import com.ansca.corona.CoronaLua;
import com.ansca.corona.CoronaRuntime;
import com.ansca.corona.CoronaRuntimeListener;
import com.ansca.corona.permissions.PermissionState;
import com.ansca.corona.permissions.PermissionsServices;
import com.ansca.corona.permissions.PermissionsSettings;
import com.naef.jnlua.JavaFunction;
import com.naef.jnlua.LuaState;
import com.naef.jnlua.NamedJavaFunction;

import java.io.IOException;
import java.io.RandomAccessFile;
import java.nio.ByteBuffer;
import java.util.Hashtable;
import java.util.LinkedList;

import plugin.microphone.LuaUtils.Scheme;
import plugin.microphone.LuaUtils.Table;


@SuppressWarnings("unused")
public class LuaLoader implements JavaFunction, CoronaRuntimeListener, AudioRecord.OnRecordPositionUpdateListener {
	private static final String EVENT_NAME = "microphone";
	private static final String RECORD_AUDIO_PERMISSION = "android.permission.RECORD_AUDIO";
	private static final int BITS_PER_SAMPLE = 16;
	private double detector_on, detector_off;
	private double gain = 1, gain_min = 0, gain_max = 0, volume_target = 0, gain_speed = 0;
	private boolean allow_clipping = false;
	private int sample_rate = 0;
	private int lua_listener = CoronaLua.REFNIL;
	private double detector_volume = 0;
	private AudioRecord audio_record;
	private HandlerThread recording_thread;
	private RandomAccessFile output_file;
	private int file_payload_size;
	private boolean is_initialized = false;
	private boolean is_recording = false;
	private boolean is_detector_on, is_detector_paused;
	private byte[] audio_buffer;
	private LinkedList<ByteBuffer> memory_buffer;

	enum ERROR_CODE {
		MISSING_MICROPHONE,
		MISSING_PERMISSION,
		DENIED_PERMISSION,
		PERMISSION_REQUEST_FAILED,
		FILE_OPEN_FAILED,
		FILE_WRITE_FAILED,
		EMPTY_RECORDING,
		INIT_FAILED,
		ALREADY_INITIALIZED
	}

	@SuppressWarnings("unused")
	public LuaLoader() {
		CoronaEnvironment.addRuntimeListener(this);
	}

	@Override
	public int invoke(LuaState L) {
		NamedJavaFunction[] lua_functions = new NamedJavaFunction[] {
			new EnableDebugWrapper(),
			new InitWrapper(),
			new StartWrapper(),
			new StopWrapper(),
			new IsRecordingWrapper(),
			new GetVolumeWrapper(),
			new GetGainWrapper(),
			new SetWrapper()
		};
		String plugin_name = L.toString( 1 );
		L.register(plugin_name, lua_functions);
		Utils.getDirPointers(L);
		Utils.setTag(plugin_name);
		return 1;
	}

	//region Corona Runtime Listener
	@Override
	public void onLoaded(CoronaRuntime runtime) {
	}

	@Override
	public void onStarted(CoronaRuntime runtime) {
	}

	@Override
	public void onSuspended(CoronaRuntime runtime) {
	}

	@Override
	public void onResumed(CoronaRuntime runtime) {
	}

	@Override
	public void onExiting(CoronaRuntime runtime) {
		CoronaLua.deleteRef(runtime.getLuaState(), lua_listener);
	}
	//endregion

	private class MicrophoneRequestPermissionsResultHandler implements CoronaActivity.OnRequestPermissionsResultHandler {
		private MicrophoneRequestPermissionsResultHandler() {
		}

		public void onHandleRequestPermissionsResult(CoronaActivity activity, int requestCode, String[] permissions, int[] grantResults) {
			PermissionsSettings permissions_settings = activity.unregisterRequestPermissionsResultHandler(this);
			if (permissions_settings != null) {
				permissions_settings.markAsServiced();
			}

			PermissionsServices permissions_services = new PermissionsServices(CoronaEnvironment.getApplicationContext());
			Hashtable<Object, Object> event = Utils.newEvent(EVENT_NAME);
			event.put(Utils.PHASE_KEY, "init");
			boolean is_error = false;
			String error_message = "";
			if (permissions_services.getPermissionStateFor(RECORD_AUDIO_PERMISSION) != PermissionState.GRANTED) {
				is_error = true;
				event.put(Utils.ERROR_CODE_KEY, ERROR_CODE.PERMISSION_REQUEST_FAILED.toString().toLowerCase());
				event.put(Utils.ERROR_MESSAGE_KEY, "User denied \"" + RECORD_AUDIO_PERMISSION + "\" permission on request.");
			} else if (init_audio_recorder()) {
				is_initialized = true;
			} else {
				is_error = true;
				event.put(Utils.ERROR_CODE_KEY, ERROR_CODE.INIT_FAILED.toString().toLowerCase());
				event.put(Utils.ERROR_MESSAGE_KEY, "Incompatible audio encoding settings.");
			}
			event.put(Utils.IS_ERROR_KEY, is_error);
			Utils.dispatchEvent(lua_listener, event);
		}
	}

	private boolean check_is_not_initialized() {
		if (!is_initialized) {
			Utils.log("the plugin is not initialized");
		}
		return !is_initialized;
	}

	private boolean init_audio_recorder() {
		recording_thread = new HandlerThread("Audio recording thread");
		recording_thread.start();
		int buffer_size = 2 * AudioRecord.getMinBufferSize(sample_rate, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT);

		audio_record = new AudioRecord(
			MediaRecorder.AudioSource.MIC,
			sample_rate,
			AudioFormat.CHANNEL_IN_MONO,
			AudioFormat.ENCODING_PCM_16BIT,
			buffer_size
		);
		if (audio_record.getState() == AudioRecord.STATE_UNINITIALIZED) {
			return false;
		}

		audio_record.setRecordPositionUpdateListener(this, new Handler(recording_thread.getLooper()));
		int period = 16 * sample_rate / 1000;  // 16ms
		audio_record.setPositionNotificationPeriod(period);
		audio_buffer = new byte[buffer_size];
		return true;
	}

	private void stop_audio_recorder() {
		is_initialized = false;
		is_recording = false;
		audio_record.stop();
		audio_record.release();
		audio_record = null;
		recording_thread.quitSafely();
		recording_thread = null;
		detector_volume = 0;
	}

	//region Lua functions
	@SuppressWarnings("unused")
	private int enable_debug(LuaState L) {
		Utils.enableDebug();
		return 0;
	}

	private int init(LuaState L) {
		Utils.checkArgCount(L, 1);

		Scheme scheme = new Scheme()
			.string("filename")
			.lightuserdata("baseDir")
			.table("detector")
			.number("detector.on")
			.number("detector.off")
			.number("sampleRate")
			.table("gain")
			.number("gain.min")
			.number("gain.max")
			.number("gain.value")
			.number("gain.target")
			.number("gain.speed")
			.bool("gain.allowClipping")
			.listener("listener");

		boolean is_error = false;
		ERROR_CODE error_code = null;
		String error_message = null;

		Table params = new Table(L, 1).parse(scheme);
		lua_listener = params.getListener("listener", CoronaLua.REFNIL);
		if (is_initialized) {
			is_error = true;
			error_code = ERROR_CODE.ALREADY_INITIALIZED;
			error_message = "Already initialized";
		}

		boolean should_request_permission = false;
		PermissionsServices permissions_services = new PermissionsServices(CoronaEnvironment.getApplicationContext());

		if (!is_error) {
			final String filename = params.getStringNotNull("filename");
			final Utils.LuaLightuserdata base_dir = params.getLightuserdata("baseDir", Utils.Dirs.documentsDirectoryPointer);
			detector_on = params.getDouble("detector.on", 0);
			detector_off = params.getDouble("detector.off", 0);
			sample_rate = params.getInteger("sampleRate", 44100);
			gain_min = params.getDouble("gain.min", 0);
			gain_max = params.getDouble("gain.max", Float.MAX_VALUE);
			gain = params.getDouble("gain.value", 1);
			volume_target = params.getDouble("gain.target", 0);
			gain_speed = params.getDouble("gain.speed", 0.1);
			allow_clipping = params.getBoolean("gain.allowClipping", false);

			gain_min = Utils.clamp(gain_min, 0, Float.MAX_VALUE);
			gain_max = Utils.clamp(gain_max, 0, Float.MAX_VALUE);
			volume_target = Utils.clamp(volume_target, 0, 1);
			gain_speed = Utils.clamp(gain_speed, 0, 1);
			gain = Utils.clamp(gain, gain_min, gain_max);

			PackageManager packageManager = CoronaEnvironment.getApplicationContext().getPackageManager();
			if (!packageManager.hasSystemFeature("android.hardware.microphone")) {
				is_error = true;
				error_code = ERROR_CODE.MISSING_MICROPHONE;
				error_message = "Device does not have a microphone";
			}

			if (!is_error) {
				PermissionState permission_state = permissions_services.getPermissionStateFor(RECORD_AUDIO_PERMISSION);
				switch (permission_state) {
					case MISSING:
						is_error = true;
						error_code = ERROR_CODE.MISSING_PERMISSION;
						error_message = "\"" + RECORD_AUDIO_PERMISSION + "\" permission is missing from the AndroidManifest file.";
						break;
					case DENIED:
						if (permissions_services.shouldNeverAskAgain(RECORD_AUDIO_PERMISSION)) {
							is_error = true;
							error_code = ERROR_CODE.DENIED_PERMISSION;
							error_message = "\"" + RECORD_AUDIO_PERMISSION + "\" permission has been denied and should not be asked again.";
						} else {
							should_request_permission = true;
						}
				}
			}

			if (!is_error) {
				String path = Utils.pathForFile(L, filename, base_dir);
				try {
					output_file = new RandomAccessFile(path, "rw");
					output_file.setLength(0); // Set file length to 0, to prevent unexpected behavior in case the file already existed.
					output_file.writeBytes("RIFF");
					output_file.writeInt(0); // Final file size not known yet, write 0.
					output_file.writeBytes("WAVE");
					output_file.writeBytes("fmt ");
					output_file.writeInt(Integer.reverseBytes(16)); // Sub-chunk size, 16 for PCM.
					output_file.writeShort(Short.reverseBytes((short) 1)); // AudioFormat, 1 for PCM.
					output_file.writeShort(Short.reverseBytes((short) 1)); // Number of channels, 1 for mono, 2 for stereo.
					output_file.writeInt(Integer.reverseBytes(sample_rate)); // Sample rate.
					output_file.writeInt(Integer.reverseBytes(sample_rate * BITS_PER_SAMPLE / 8)); // Byte rate, SampleRate * NumberOfChannels * BitsPerSample / 8.
					output_file.writeShort(Short.reverseBytes((short) (BITS_PER_SAMPLE / 8))); // Block align, NumberOfChannels * BitsPerSample / 8.
					output_file.writeShort(Short.reverseBytes((short) BITS_PER_SAMPLE)); // Bits per sample.
					output_file.writeBytes("data");
					output_file.writeInt(0); // Data chunk size not known yet, write 0.
				} catch (IOException e) {
					is_error = true;
					error_code = ERROR_CODE.FILE_OPEN_FAILED;
					error_message = "File " + path + " can't be opened for writing.";
				}
			}

			file_payload_size = 0;
			detector_volume = 0;
			is_detector_on = false;
			is_detector_paused = false;
			memory_buffer = new LinkedList<>();
		}

		if (is_error) {
			Hashtable<Object, Object> event = Utils.newEvent(EVENT_NAME);
			event.put(Utils.PHASE_KEY, "init");
			event.put(Utils.IS_ERROR_KEY, true);
			event.put(Utils.ERROR_CODE_KEY, error_code.toString().toLowerCase());
			event.put(Utils.ERROR_MESSAGE_KEY, error_message);
			Utils.dispatchEvent(lua_listener, event);
		} else if (should_request_permission) {
			permissions_services.requestPermissions(new PermissionsSettings(RECORD_AUDIO_PERMISSION), new MicrophoneRequestPermissionsResultHandler());
		} else {
			Hashtable<Object, Object> event = Utils.newEvent(EVENT_NAME);
			event.put(Utils.PHASE_KEY, "init");
			if (init_audio_recorder()) {
				is_initialized = true;
				event.put(Utils.IS_ERROR_KEY, false);
			} else {
				event.put(Utils.IS_ERROR_KEY, true);
				event.put(Utils.ERROR_CODE_KEY, ERROR_CODE.INIT_FAILED.toString().toLowerCase());
				event.put(Utils.ERROR_MESSAGE_KEY, "Incompatible audio encoding settings.");
			}
			Utils.dispatchEvent(lua_listener, event);
		}

		return 0;
	}

	private int start(LuaState L) {
		Utils.checkArgCount(L, 0);
		if (check_is_not_initialized() || is_recording) {
			return 0;
		}
		audio_record.startRecording();
		is_recording = true;
		return 0;
	}

	private int stop(LuaState L) {
		Utils.checkArgCount(L, 0);
		if (check_is_not_initialized() || !is_recording) {
			return 0;
		}
		stop_audio_recorder();
		boolean is_error = false;
		if (file_payload_size > 0) {
			try {
				// Add one buffer to smooth ON->OFF transition.
				if (!memory_buffer.isEmpty()) {
					byte[] buffer = memory_buffer.removeFirst().array();
					output_file.write(buffer);
					file_payload_size += buffer.length;
				}
				output_file.seek(4); // Write size to RIFF header.
				output_file.writeInt(Integer.reverseBytes(36 + file_payload_size));
				output_file.seek(40); // Write size to Subchunk2Size field.
				output_file.writeInt(Integer.reverseBytes(file_payload_size));
				output_file.close();
			} catch (IOException e) {
				is_error = true;
			}
		} else {
			is_error = true;
		}

		Hashtable<Object, Object> event = Utils.newEvent(EVENT_NAME);
		event.put(Utils.PHASE_KEY, "recorded");
		event.put(Utils.IS_ERROR_KEY, is_error);
		if (is_error) {
			if (file_payload_size == 0) {
				event.put(Utils.ERROR_CODE_KEY, ERROR_CODE.EMPTY_RECORDING.toString().toLowerCase());
				event.put(Utils.ERROR_MESSAGE_KEY, "The recording is empty.");
			} else {
				event.put(Utils.ERROR_CODE_KEY, ERROR_CODE.FILE_WRITE_FAILED.toString().toLowerCase());
				event.put(Utils.ERROR_MESSAGE_KEY, "Failed to write to the file. (2)");
			}
		}
		Utils.dispatchEvent(lua_listener, event);
		return 0;
	}

	private int is_recording_(LuaState L) {
		Utils.checkArgCount(L, 0);
		L.pushBoolean(is_recording);
		return 1;
	}

	private int get_volume(LuaState L) {
		Utils.checkArgCount(L, 0);
		L.pushNumber(detector_volume);
		return 1;
	}

	private int get_gain(LuaState L) {
		Utils.checkArgCount(L, 0);
		L.pushNumber(gain);
		return 1;
	}

	private int set(LuaState L) {
		Utils.checkArgCount(L, 1);
		Scheme scheme = new Scheme()
			.table("detector")
			.number("detector.on")
			.number("detector.off")
			.table("gain")
			.number("gain.min")
			.number("gain.max")
			.number("gain.value")
			.number("gain.target")
			.number("gain.speed")
			.bool("gain.allowClipping");

		Table params = new Table(L, 1).parse(scheme);
		detector_on = params.getDouble("detector.on", detector_on);
		detector_off = params.getDouble("detector.off", detector_off);
		gain_min = params.getDouble("gain.min", gain_min);
		gain_max = params.getDouble("gain.max", gain_max);
		gain = params.getDouble("gain.value", gain);
		volume_target = params.getDouble("gain.target", volume_target);
		gain_speed = params.getDouble("gain.speed", gain_speed);
		allow_clipping = params.getBoolean("gain.allowClipping", allow_clipping);

		gain_min = Utils.clamp(gain_min, 0, Float.MAX_VALUE);
		gain_max = Utils.clamp(gain_max, 0, Float.MAX_VALUE);
		volume_target = Utils.clamp(volume_target, 0, 1);
		gain_speed = Utils.clamp(gain_speed, 0, 1);
		gain = Utils.clamp(gain, gain_min, gain_max);
		return 0;
	}
	//endregion

	//region AudioRecord.OnRecordPositionUpdateListener
	public void onPeriodicNotification(AudioRecord recorder) {
		if (audio_record != null) {
			int count = audio_record.read(audio_buffer, 0, audio_buffer.length);
			int sample_count = count / 2;
			if (count > 0 && is_recording) {
				if (volume_target > 0) {
					if (detector_volume > 0) {
						gain = gain + gain_speed * (volume_target - detector_volume);
						gain = Utils.clamp(gain, gain_min, gain_max);
					}
					double rms = 0;
					if (!allow_clipping) {
						int max_value = 0;
						for (int i = 0; i < count; i += 2) {
							int value = audio_buffer[i] + (audio_buffer[i + 1] << 8);
							if (value > max_value) {
								max_value = value;
							}
						}
						if (max_value * gain > 32768) {
							gain = 32768.0 / max_value;
						}
					}
					for (int i = 0; i < count; i += 2) {
						int value = audio_buffer[i] + (audio_buffer[i + 1] << 8);
						value *= gain;
						rms += Math.pow(value / 32768.0, 2.0);
						audio_buffer[i] = (byte)(value & 0x00FF);
						audio_buffer[i + 1] = (byte)(value >> 8);
					}
					detector_volume = Math.sqrt(rms / sample_count);
				} else {
					double rms = 0;
					for (int i = 0; i < count; i += 2) {
						int value = audio_buffer[i] + (audio_buffer[i + 1] << 8);
						double normal = value / 32768f;
						rms += normal * normal;
					}
					detector_volume = Math.sqrt(rms / sample_count);
				}
				if (is_detector_on || detector_volume >= detector_on) {
					if (!is_detector_on) {
						Utils.debugLog("Detector is ON.");
						is_detector_on = true;
					}
					if (detector_volume > detector_off) {
						if (is_detector_paused) {
							Utils.debugLog("Detector is RESUMED.");
							is_detector_paused = false;
						}
						try {
							while (!memory_buffer.isEmpty()) {
								byte[] buffer = memory_buffer.removeFirst().array();
								output_file.write(buffer);
								file_payload_size += buffer.length;
							}
							output_file.write(audio_buffer);
							file_payload_size += count;
						} catch (IOException e) {
							stop_audio_recorder();
							Hashtable<Object, Object> event = Utils.newEvent(EVENT_NAME);
							event.put(Utils.PHASE_KEY, "recorded");
							event.put(Utils.IS_ERROR_KEY, true);
							event.put(Utils.ERROR_CODE_KEY, ERROR_CODE.FILE_WRITE_FAILED.toString().toLowerCase());
							event.put(Utils.ERROR_MESSAGE_KEY, "Failed to write to the file. (1)");
							Utils.dispatchEvent(lua_listener, event);
						}
					} else {
						if (!is_detector_paused) {
							Utils.debugLog("Detector is PAUSED.");
							is_detector_paused = true;
						}
						memory_buffer.add(ByteBuffer.allocate(count).put(audio_buffer, 0, count));
					}
				} else {
					// Add one buffer to smooth OFF->ON transition.
					memory_buffer.clear();
					memory_buffer.add(ByteBuffer.allocate(count).put(audio_buffer, 0, count));
				}
			}
		}
	}
	public void onMarkerReached(AudioRecord recorder) {
	}
	//endregion

	//region Lua wrappers
	@SuppressWarnings("unused")
	private class EnableDebugWrapper implements NamedJavaFunction {
		@Override
		public String getName() {
			return "enableDebug";
		}
		@Override
		public int invoke(LuaState L) {
			return enable_debug(L);
		}
	}

	@SuppressWarnings("unused")
	private class InitWrapper implements NamedJavaFunction {
		@Override
		public String getName() {
			return "init";
		}
		@Override
		public int invoke(LuaState L) {
			return init(L);
		}
	}

	@SuppressWarnings("unused")
	private class StartWrapper implements NamedJavaFunction {
		@Override
		public String getName() {
			return "start";
		}

		@Override
		public int invoke(LuaState L) {
			return start(L);
		}
	}

	@SuppressWarnings("unused")
	private class StopWrapper implements NamedJavaFunction {
		@Override
		public String getName() {
			return "stop";
		}

		@Override
		public int invoke(LuaState L) {
			return stop(L);
		}
	}

	@SuppressWarnings("unused")
	private class IsRecordingWrapper implements NamedJavaFunction {
		@Override
		public String getName() {
			return "isRecording";
		}

		@Override
		public int invoke(LuaState L) {
			return is_recording_(L);
		}
	}

	@SuppressWarnings("unused")
	private class GetVolumeWrapper implements NamedJavaFunction {
		@Override
		public String getName() {
			return "getVolume";
		}

		@Override
		public int invoke(LuaState L) {
			return get_volume(L);
		}
	}

	@SuppressWarnings("unused")
	private class GetGainWrapper implements NamedJavaFunction {
		@Override
		public String getName() {
			return "getGain";
		}

		@Override
		public int invoke(LuaState L) {
			return get_gain(L);
		}
	}

	@SuppressWarnings("unused")
	private class SetWrapper implements NamedJavaFunction {
		@Override
		public String getName() {
			return "set";
		}

		@Override
		public int invoke(LuaState L) {
			return set(L);
		}
	}
	//endregion
}
