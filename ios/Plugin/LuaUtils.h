#ifndef LuaUtils_h
#define LuaUtils_h

#if TARGET_OS_IPHONE
#import <UIKit/UIKit.h>
#elif TARGET_OS_MAC
#import <AppKit/AppKit.h>
#endif
#import "CoronaLua.h"

@interface LuaTask : NSObject
@property(nonatomic) int listener;
@property(nonatomic,retain) NSDictionary *event;
@property(nonatomic) bool delete_ref;
@end

@interface LuaLightuserdata : NSObject
-(instancetype)init:(void*)pointer;
-(void*)getPointer;
@end

@interface LuaUtils : NSObject

+(void)setTag:(NSString*)tag;
+(void)enableDebug;
+(void)debugLog:(NSString*)message;
+(void)log:(NSString*)message;
+(void)checkArgCount:(lua_State*)L count:(int)countExact;
+(void)checkArgCount:(lua_State*)L from:(int)countFrom to:(int)countTo;
+(int)newRef:(lua_State*)L index:(int)index;
+(void)deleteRefIfNotNil:(int)ref;
+(void)put:(NSMutableDictionary*)hastable key:(NSString*)key value:(NSObject*)value;
+(NSMutableDictionary*)newEvent:(NSString*)name;
+(NSMutableDictionary*)newLegacyEvent:(NSString*)name;
+(void)dispatchEventNumber:(NSNumber*)listener event:(NSMutableDictionary*)event;
+(void)dispatchEventNumber:(NSNumber*)listener event:(NSMutableDictionary*)event deleteRef:(bool)deleteRef;
+(void)dispatchEvent:(int)listener event:(NSMutableDictionary*)event;
+(void)dispatchEvent:(int)listener event:(NSMutableDictionary*)event deleteRef:(bool)deleteRef;
+(void)setCFunctionAsField:(lua_State*)L name:(const char*)name function:(lua_CFunction)function;
+(void)setCClosureAsField:(lua_State*)L name:(const char*)name function:(lua_CFunction)function upvalue:(void*)upvalue;
+(void)getDirPointers:(lua_State*)L;
+(LuaLightuserdata*)getResourceDirectory;
+(LuaLightuserdata*)getDocumentsDirectory;
+(LuaLightuserdata*)getCachesDirectory;
+(LuaLightuserdata*)getTemporaryDirectory;
+(NSString*)baseDirToString:(LuaLightuserdata*)baseDir;
+(NSString*)pathForFile:(lua_State*)L filename:(NSString*)filename baseDir:(NSString*)baseDir;
#if TARGET_OS_IPHONE
+(UIImage*)getBitmap:(lua_State*)L filename:(NSString*)filename baseDir:(LuaLightuserdata*)baseDir;
#elif TARGET_OS_MAC
+(NSImage*)getBitmap:(lua_State*)L filename:(NSString*)filename baseDir:(LuaLightuserdata*)baseDir;
#endif
+(void)pushValue:(lua_State*)L value:(NSObject*)object;
+(void)pushHashtable:(lua_State*)L hashtable:(NSDictionary*)hashtable;
+(void)executeTasks:(lua_State*)L;

@end

@interface Scheme : NSObject
@property(nonatomic, readonly) int LuaTypeNumeric;
@property(nonatomic, readonly) int LuaTypeByteArray;
@property(nonatomic, readonly) int LuaTypeAny;
-(void)any:(NSString*)path;
-(void)string:(NSString*)path;
-(void)number:(NSString*)path;
-(void)boolean:(NSString*)path;
-(void)table:(NSString*)path;
-(void)function:(NSString*)path;
-(void)listener:(NSString*)path;
-(void)listener:(NSString*)path name:(NSString*)eventName;
-(void)lightuserdata:(NSString*)path;
-(void)userdata:(NSString*)path;
-(void)numeric:(NSString*)path;
-(void)byteArray:(NSString*)path;
-(id)get:(NSString*)path;

@end

@interface Table : NSObject

-(id)init:(lua_State*)L index:(int)index;
-(void)parse:(Scheme*)scheme;
-(bool)getBoolean:(NSString*)path default:(bool)defaultValue;
-(NSNumber*)getBoolean:(NSString*)path;
-(NSString*)getString:(NSString*)path default:(NSString*)defaultValue;
-(NSString*)getString:(NSString*)path;
-(NSString*)getStringNotNull:(NSString*)path;
-(double)getDouble:(NSString*)path default:(double)defaultValue;
-(NSNumber*)getDouble:(NSString*)path;
-(double)getDoubleNotNull:(NSString*)path;
-(int)getInteger:(NSString*)path default:(int)defaultValue;
-(NSNumber*)getInteger:(NSString*)path;
-(int)getIntegerNotNull:(NSString*)path;
-(long)getLong:(NSString*)path default:(long)defaultValue;
-(NSNumber*)getLong:(NSString*)path;
-(long)getLongNotNull:(NSString*)path;
-(NSData*)getByteArray:(NSString*)path default:(NSData*)defaultValue;
-(NSData*)getByteArray:(NSString*)path;
-(NSData*)getByteArrayNotNull:(NSString*)path;
-(LuaLightuserdata*)getLightuserdata:(NSString*)path default:(LuaLightuserdata*)defaultValue;
-(LuaLightuserdata*)getLightuserdata:(NSString*)path;
-(LuaLightuserdata*)getLightuserdataNotNull:(NSString*)pat;
-(int)getListener:(NSString*)path default:(int)defaultValue;
-(NSNumber*)getListener:(NSString*)path;
-(NSDictionary*)getTable:(NSString*)path default:(NSDictionary*)defaultValue;
-(NSDictionary*)getTable:(NSString*)path;

@end

@protocol LuaPushable
-(void)push:(lua_State*)L;
@end

#endif
