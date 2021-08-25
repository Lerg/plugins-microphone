#import <Foundation/Foundation.h>
#import "CoronaAssert.h"

#import "LuaUtils.h"

@implementation LuaTask
@end

@implementation LuaUtils

static NSString* TAG = @"plugin";
static bool isDebug = false;
static lua_State* _L;
static NSMutableArray *tasks = nil;

static const NSString* ResourceDirectory = @"ResourceDirectory";
static const NSString* DocumentsDirectory = @"DocumentsDirectory";
static const NSString* CachesDirectory = @"CachesDirectory";
static const NSString* TemporaryDirectory = @"TemporaryDirectory";
static LuaLightuserdata* resourceDirectoryPointer;
static LuaLightuserdata* documentsDirectoryPointer;
static LuaLightuserdata* cachesDirectoryPointer;
static LuaLightuserdata* temporaryDirectoryPointer;

+ (id)alloc {
	[NSException raise:@"Cannot be instantiated!" format:@"Static class 'LuaUtils' cannot be instantiated!"];
	return nil;
}

+(void)setTag:(NSString*)tag {
	TAG = tag;
}

+(void)enableDebug {
	isDebug = true;
}

+(void)debugLog:(NSString*)message {
	if (isDebug) {
		NSLog(@"%@: %@", TAG, message);
	}
}

+(void)log:(NSString*)message {
	NSLog(@"%@: %@", TAG, message);
}

+(void)checkArgCount:(lua_State*)L count:(int)countExact {
	int count = lua_gettop(L);
	[LuaUtils assert:count == countExact message:[NSString stringWithFormat:@"This function requires %d arguments. Got %d.", countExact, count]];
}

+(void)checkArgCount:(lua_State*)L from:(int)countFrom to:(int)countTo {
	int count = lua_gettop(L);
	[LuaUtils assert:count >= countFrom && count <= countTo message:[NSString stringWithFormat:@"This function requires from %d to %d arguments. Got %d.", countFrom, countTo, count]];
}

+(void)assert:(bool)condition message:(NSString*)message {
	if (!condition) {
		luaL_error(_L, [message UTF8String]);
	}
}

+(int)newRef:(lua_State*)L index:(int)index {
	lua_pushvalue(L, index);
	return luaL_ref(L, LUA_REGISTRYINDEX);
}

+(void)deleteRefIfNotNil:(int)ref {
	if ((ref != LUA_REFNIL) && (ref != LUA_NOREF)) {
		luaL_unref(_L, LUA_REGISTRYINDEX, ref);
	}
}

+(void)put:(NSMutableDictionary*)hastable key:(NSString*)key value:(NSObject*)value {
	if (value != nil) {
		[hastable  setObject:value forKey:key];
	}
}

+(NSMutableDictionary*)newEvent:(NSString*)name {
	NSMutableDictionary* event = [NSMutableDictionary dictionaryWithDictionary:@{@"name" : name}];
	return event;
}

+(NSMutableDictionary*)newLegacyEvent:(NSString*)name {
	NSMutableDictionary* event = [self newEvent:name];
	[event setObject:name forKey:@"type"];
	return event;
}

+(void)dispatchEventNumber:(NSNumber*)listener event:(NSMutableDictionary*)event {
	[self dispatchEventNumber:listener event:event deleteRef:false];
}

+(void)dispatchEventNumber:(NSNumber*)listener event:(NSMutableDictionary*)event deleteRef:(bool)deleteRef {
	if (listener != nil) {
		[self dispatchEvent:[listener intValue] event:event deleteRef:deleteRef];
	}
}

+(void)dispatchEvent:(int)listener event:(NSMutableDictionary*)event {
	[self dispatchEvent:listener event:event deleteRef:false];
}

+(void)dispatchEvent:(int)listener event:(NSMutableDictionary*)event deleteRef:(bool)deleteRef {
	if ((listener == LUA_REFNIL) || (listener == LUA_NOREF)) {
		return;
	}
	LuaTask *task = [[LuaTask alloc] init];
	task.listener = listener;
	task.event = [NSDictionary dictionaryWithDictionary:event];
	task.delete_ref = deleteRef;
	if (tasks == nil) {
		tasks = [[NSMutableArray alloc] init];
	}
	[tasks addObject:task];
}

+(void)setCFunctionAsField:(lua_State*)L name:(const char*)name function:(lua_CFunction)function {
	lua_pushcfunction(L, function);
	lua_setfield(L, -2, name);
}

+(void)setCClosureAsField:(lua_State*)L name:(const char*)name function:(lua_CFunction)function upvalue:(void*)upvalue {
	lua_pushlightuserdata(L, upvalue);
	lua_pushcclosure(L, function, 1);
	lua_setfield(L, -2, name);
}

+(void)getDirPointers:(lua_State*)L {
	lua_getglobal(L, "system");

	lua_getfield(L, -1, [ResourceDirectory UTF8String]);
	resourceDirectoryPointer = [[LuaLightuserdata alloc] init:lua_touserdata(L, -1)];
	lua_pop(L, 1);

	lua_getfield(L, -1, [DocumentsDirectory UTF8String]);
	documentsDirectoryPointer = [[LuaLightuserdata alloc] init:lua_touserdata(L, -1)];
	lua_pop(L, 1);

	lua_getfield(L, -1, [CachesDirectory UTF8String]);
	cachesDirectoryPointer = [[LuaLightuserdata alloc] init:lua_touserdata(L, -1)];
	lua_pop(L, 1);

	lua_getfield(L, -1, [TemporaryDirectory UTF8String]);
	temporaryDirectoryPointer = [[LuaLightuserdata alloc] init:lua_touserdata(L, -1)];
	lua_pop(L, 1);

	lua_pop(L, 1);
}

+(LuaLightuserdata*)getResourceDirectory {
	return resourceDirectoryPointer;
}

+(LuaLightuserdata*)getDocumentsDirectory {
	return documentsDirectoryPointer;
}

+(LuaLightuserdata*)getCachesDirectory {
	return cachesDirectoryPointer;
}

+(LuaLightuserdata*)getTemporaryDirectory {
	return temporaryDirectoryPointer;
}

+(NSString*)baseDirToString:(LuaLightuserdata*)baseDir {
	void* baseDirPointer = [baseDir getPointer];
	if (baseDirPointer == [resourceDirectoryPointer getPointer]) {
		return [ResourceDirectory copy];
	} else if (baseDirPointer == [documentsDirectoryPointer getPointer]) {
		return [DocumentsDirectory copy];
	} else if (baseDirPointer == [cachesDirectoryPointer getPointer]) {
		return [CachesDirectory copy];
	} else if (baseDirPointer == [temporaryDirectoryPointer getPointer]) {
		return [TemporaryDirectory copy];
	}
	return nil;
}

+(NSString*)pathForFile:(lua_State*)L filename:(NSString*)filename baseDir:(NSString*)baseDir {
	if ((filename != nil) && baseDir != nil) {
		lua_getglobal(L, "system");
		lua_getfield(L, -1, "pathForFile");
		lua_pushstring(L, [filename UTF8String]);
		lua_getfield(L, -3, [baseDir UTF8String]);
		lua_call(L, 2, 1);  // Call system.pathForFile() with 2 arguments and 1 return value.
		NSString* path = @(lua_tostring(L, -1));
		lua_pop(L, 1);
		return  path;
	}
	return nil;
}

#if TARGET_OS_IPHONE
+(UIImage*)getBitmap:(lua_State*)L filename:(NSString*)filename baseDir:(LuaLightuserdata*)baseDir {
	NSString* imageFile = [self pathForFile:L filename:filename baseDir:[self baseDirToString:baseDir]];
	return [UIImage imageWithContentsOfFile:imageFile];
}
#elif TARGET_OS_MAC
+(NSImage*)getBitmap:(lua_State*)L filename:(NSString*)filename baseDir:(LuaLightuserdata*)baseDir {
	NSString* imageFile = [self pathForFile:L filename:filename baseDir:[self baseDirToString:baseDir]];
	return [[NSImage alloc] initWithContentsOfFile:imageFile];
}
#endif

+(void)pushValue:(lua_State*)L value:(NSObject*)object {
	if (object == nil) {
		lua_pushnil(L);
	} else if ([object isKindOfClass:[NSString class]]) {
		lua_pushstring(L, [(NSString*)object UTF8String]);
	} else if ([object isKindOfClass:[NSNumber class]]) {
		NSNumber* number = (NSNumber*)object;
		const char* cType = [number objCType];
		if ([number isKindOfClass:NSClassFromString(@"__NSCFBoolean")]) {
			lua_pushboolean(L, [number boolValue]);
		} else if ((strcmp(cType, @encode(short))) == 0) {
            lua_pushinteger(L, [number intValue]);
		} else if ((strcmp(cType, @encode(int))) == 0) {
			lua_pushinteger(L, [number intValue]);
		} else if ((strcmp(cType, @encode(long))) == 0) {
			lua_pushnumber(L, [number doubleValue]);
		} else if ((strcmp(cType, @encode(long long))) == 0) {
			lua_pushnumber(L, [number doubleValue]);
		} else if ((strcmp(cType, @encode(float))) == 0) {
			lua_pushnumber(L, [number doubleValue]);
		} else if ((strcmp(cType, @encode(double))) == 0) {
			lua_pushnumber(L, [number doubleValue]);
		} else if ((strcmp(cType, @encode(BOOL))) == 0) {
			lua_pushboolean(L, [number boolValue]);
		} else {
			luaL_error(L, "LuaUtils.pushValue(): failed to push an NSNumber value. C type: %s", cType);
		}
	} else if([object isKindOfClass:[NSData class]]) {
		lua_pushstring(L, (const char*)[(NSData*)object bytes]);
	} else if ([object isKindOfClass:[LuaLightuserdata class]]) {
		lua_pushlightuserdata(L, [(LuaLightuserdata*)object getPointer]);
	/*} else if(object instanceof LuaValue) {
		LuaValue value = (LuaValue) object;
		L.ref(value.reference);
		value.delete(L);*/
	} else if ([object conformsToProtocol:@protocol(LuaPushable)]) {
		[(NSObject <LuaPushable>*)object push:L];
	} else if ([object isKindOfClass:[NSArray class]]) {
		NSMutableDictionary* hashtable = [NSMutableDictionary dictionary];
		int i = 1;
		for (id o in (NSArray*)object) {
			[hashtable setObject:o forKey:@(i)];
		}
		[self pushHashtable:L hashtable:hashtable];
	} else if ([object isKindOfClass:[NSDictionary class]]) {
		[self pushHashtable:L hashtable:(NSDictionary*)object];
	} else {
		luaL_error(L, "LuaUtils.pushValue(): failed to push an object: %s", [object description]);
	}
}

+(void)pushHashtable:(lua_State*)L hashtable:(NSDictionary*)hashtable {
	if (hashtable == nil) {
		lua_newtable(L);
	} else {
		lua_newtable(L);
		int tableIndex = lua_gettop(L);
		for (id key in hashtable) {
			[self pushValue:L value:key];
			[self pushValue:L value:[hashtable objectForKey:key]];
			lua_settable(L, tableIndex);
		}
	}
}

+(void)executeTasks:(lua_State*)L {
	_L = L;
	while (tasks.count > 0) {
		LuaTask *task = tasks.firstObject;
		lua_rawgeti(L, LUA_REGISTRYINDEX, task.listener);
		[self pushHashtable:L hashtable:task.event];
		lua_call(L, 1, 0);
		if (task.delete_ref) {
			luaL_unref(L, LUA_REGISTRYINDEX, task.listener);
		}
		[tasks removeObjectAtIndex:0];
	}
}

@end

@implementation LuaLightuserdata {
	void* lightuserdata;
}

-(instancetype)init:(void*)pointer {
	self = [super init];
	lightuserdata = pointer;
	return self;
}

-(void*)getPointer {
	return lightuserdata;
}

@end

/*
static class LuaValue {
	int reference = CoronaLua.REFNIL;

	LuaValue(LuaState L, int index) {
		reference = CoronaLua.newRef(L, index);
	}

	void delete(LuaState L) {
		if (reference != CoronaLua.REFNIL) {
			CoronaLua.deleteRef(L, reference);
		}
	}
}*/

@implementation Table {
	lua_State* _L;
	int _index;
	NSMutableDictionary* _hashtable;
	Scheme* _scheme;
}
-(id)init:(lua_State*)L index:(int)index {
	self = [super init];
	_L = L;
	_index = index;
	return self;
}

-(void)parse:(Scheme*)scheme {
	_scheme = scheme;
	_hashtable = [self toHashtable:_L index:_index pathList:nil];
}


-(bool)getBoolean:(NSString*)path default:(bool)defaultValue {
	NSNumber* result = [self getBoolean:path];
	if (result != nil) {
		return [result boolValue];
	} else {
		return defaultValue;
	}
}

-(NSNumber*)getBoolean:(NSString*)path {
	id object = [self get:path];
	if (object != nil && [object isKindOfClass:[NSNumber class]] && (((strcmp([object objCType], @encode(BOOL))) == 0) || [object isKindOfClass:NSClassFromString(@"__NSCFBoolean")])) {
		return (NSNumber*)object;
	} else {
		return nil;
	}
}

-(NSString*)getString:(NSString*)path default:(NSString*)defaultValue {
	NSString* result = [self getString:path];
	if (result != nil) {
		return result;
	} else {
		return defaultValue;
	}
}

-(NSString*)getString:(NSString*)path {
	id object = [self get:path];
	if (object != nil && [object isKindOfClass:[NSString class]]) {
		return (NSString*)object;
	} else {
		return nil;
	}
}

-(NSString*)getStringNotNull:(NSString*)path {
	NSString* result = [self getString:path];
	[LuaUtils assert:result != nil message:[NSString stringWithFormat:@"Table's property '%@' is not a string.", path]];
	return result;
}

-(double)getDouble:(NSString*)path default:(double)defaultValue {
	NSNumber* result = [self getDouble:path];
	if (result != nil) {
		return [result doubleValue];
	} else {
		return defaultValue;
	}
}

-(NSNumber*)getDouble:(NSString*)path {
	id object = [self get:path];
	if (object != nil && [object isKindOfClass:[NSNumber class]]) {
		return (NSNumber*)object;
	} else {
		return nil;
	}
}

-(double)getDoubleNotNull:(NSString*)path {
	NSNumber* result = [self getDouble:path];
	[LuaUtils assert:result != nil message:[NSString stringWithFormat:@"Table's property '%@' is not a number.", path]];
	return [result doubleValue];
}

-(int)getInteger:(NSString*)path default:(int)defaultValue {
	NSNumber* result = [self getInteger:path];
	if (result != nil) {
		return [result intValue];
	} else {
		return defaultValue;
	}
}

-(NSNumber*)getInteger:(NSString*)path {
	id object = [self get:path];
	if (object != nil && [object isKindOfClass:[NSNumber class]]) {
		return (NSNumber*)object;
	} else {
		return nil;
	}
}

-(int)getIntegerNotNull:(NSString*)path {
	NSNumber* result = [self getInteger:path];
	[LuaUtils assert:result != nil message:[NSString stringWithFormat:@"Table's property '%@' is not a number.", path]];
	return [result intValue];
}

-(long)getLong:(NSString*)path default:(long)defaultValue {
	NSNumber* result = [self getLong:path];
	if (result != nil) {
		return [result longValue];
	} else {
		return defaultValue;
	}
}

-(NSNumber*)getLong:(NSString*)path {
	id object = [self get:path];
	if (object != nil && [object isKindOfClass:[NSNumber class]]) {
		return (NSNumber*)object;
	} else {
		return nil;
	}
}

-(long)getLongNotNull:(NSString*)path {
	NSNumber* result = [self getLong:path];
	[LuaUtils assert:result != nil message:[NSString stringWithFormat:@"Table's property '%@' is not a number.", path]];
	return [result longValue];
}

-(NSData*)getByteArray:(NSString*)path default:(NSData*)defaultValue {
	NSData* result = [self getByteArray:path];
	if (result != nil) {
		return result;
	} else {
		return defaultValue;
	}
}

-(NSData*)getByteArray:(NSString*)path {
	id object = [self get:path];
	if (object != nil && [object isKindOfClass:[NSData class]]) {
		return (NSData*)object;
	} else {
		return nil;
	}
}

-(NSData*)getByteArrayNotNull:(NSString*)path {
	NSData* result = [self getByteArray:path];
	[LuaUtils assert:result != nil message:[NSString stringWithFormat:@"Table's property '%@' is not a byte array.", path]];
	return result;
}

-(LuaLightuserdata*)getLightuserdata:(NSString*)path default:(LuaLightuserdata*)defaultValue {
	LuaLightuserdata* result = [self getLightuserdata:path];
	if (result != nil) {
		return result;
	} else {
		return defaultValue;
	}
}

-(LuaLightuserdata*)getLightuserdata:(NSString*)path {
	id object = [self get:path];
	if (object != nil && [object isKindOfClass:[LuaLightuserdata class]]) {
		return (LuaLightuserdata*)object;
	} else {
		return nil;
	}
}

-(LuaLightuserdata*)getLightuserdataNotNull:(NSString*)path {
	LuaLightuserdata* result = [self getLightuserdata:path];
	[LuaUtils assert:result != nil message:[NSString stringWithFormat:@"Table's property '%@' is not a lightuserdata.", path]];
	return result;
}

-(int)getListener:(NSString*)path default:(int)defaultValue {
	NSNumber* result = [self getListener:path];
	if (result != nil) {
		return [result intValue];
	} else {
		return defaultValue;
	}
}

-(NSNumber*)getListener:(NSString*)path {
	id object = [self get:path];
	if (object != nil && [object isKindOfClass:[NSNumber class]]) {
		return (NSNumber*)object;
	} else {
		return nil;
	}
}

-(NSDictionary*)getTable:(NSString*)path default:(NSDictionary*)defaultValue {
    NSDictionary* result = [self getTable:path];
    if (result != nil) {
        return result;
    } else {
        return defaultValue;
    }
}

-(NSDictionary*)getTable:(NSString*)path {
	id object = [self get:path];
	if (object != nil && [object isKindOfClass:[NSMutableDictionary class]]) {
		return [NSDictionary dictionaryWithDictionary:(NSMutableDictionary*)[self get:path]];
	} else {
		return nil;
	}
}

-(id)get:(NSString*)path {
	if ([path isEqualToString:@""]) {
		return _hashtable;
	} else {
		id current = nil;
		for (NSString* p in [path componentsSeparatedByString:@"."]) {
			if (current == nil) {
				current = [_hashtable objectForKey:p];
			} else if ([current isKindOfClass:[NSMutableDictionary class]]) {
				NSMutableDictionary* h = (NSMutableDictionary*)current;
				current = [h objectForKey:p];
			}
		}
		return current;
	}
}

-(id)toValue:(lua_State*)L index:(int)index pathList:(NSMutableArray*)pathList {
	if ((index < 0) && (index > LUA_REGISTRYINDEX)) {
		index = lua_gettop(L) + index + 1;
	}
	id o = nil;
	if (_scheme == nil) {
		switch (lua_type(L, index)) {
			case LUA_TSTRING:
				o = @(lua_tostring(L, index));
				break;
			case LUA_TNUMBER:
				o = @(lua_tonumber(L, index));
				break;
			case LUA_TBOOLEAN:
				o = [NSNumber numberWithBool:lua_toboolean(L, index)];
				break;
			case LUA_TLIGHTUSERDATA:
				o = [[LuaLightuserdata alloc] init:lua_touserdata(L, index)];
				break;
			case LUA_TTABLE:
				o = [self toHashtable:L index:index pathList:pathList];
				break;
		}
	} else {
		NSString* path = [pathList componentsJoinedByString: @"."];
		NSObject* rule = [_scheme get:path];
		if (rule == nil) {
			NSMutableArray *path_copy = [pathList mutableCopy];
			path_copy[path_copy.count - 1] = @"*";
			rule = [_scheme get:[path_copy componentsJoinedByString:@"."]];
		}
		switch (lua_type(L, index)) {
			case LUA_TSTRING:
				if ([rule isKindOfClass:[NSNumber class]] && ([(NSNumber*)rule intValue] == LUA_TSTRING || [(NSNumber*)rule intValue] == _scheme.LuaTypeAny)) {
					o = @(lua_tostring(L, index));
				} else if ([rule isKindOfClass:[NSNumber class]] && [(NSNumber*)rule intValue] == _scheme.LuaTypeNumeric) {
					NSString* value = @(lua_tostring(L, index));
					bool isNumeric = [[@([value doubleValue]) stringValue] isEqualToString:value] || [[@([value intValue]) stringValue] isEqualToString:value];
					if (isNumeric) {
						o = value;
					}
				} else if ([rule isKindOfClass:[NSNumber class]] && [(NSNumber*)rule intValue] == _scheme.LuaTypeByteArray) {
					//o = L.toByteArray(index);
				}
				break;
			case LUA_TNUMBER:
				if ([rule isKindOfClass:[NSNumber class]] && (([(NSNumber*)rule intValue] == LUA_TNUMBER) || ([(NSNumber*)rule intValue] == _scheme.LuaTypeNumeric || [(NSNumber*)rule intValue] == _scheme.LuaTypeAny))) {
					o = @(lua_tonumber(L, index));
				}
				break;
			case LUA_TBOOLEAN:
				if ([rule isKindOfClass:[NSNumber class]] && ([(NSNumber*)rule intValue] == LUA_TBOOLEAN || [(NSNumber*)rule intValue] == _scheme.LuaTypeAny)) {
					o = [NSNumber numberWithBool:lua_toboolean(L, index)];
				}
				break;
			case LUA_TLIGHTUSERDATA:
				if ([rule isKindOfClass:[NSNumber class]] && ([(NSNumber*)rule intValue] == LUA_TLIGHTUSERDATA || [(NSNumber*)rule intValue] == _scheme.LuaTypeAny)) {
					o = [[LuaLightuserdata alloc] init:lua_touserdata(L, index)];
				}
				break;
			case LUA_TUSERDATA:
				if ([rule isKindOfClass:[NSNumber class]] && ([(NSNumber*)rule intValue] == LUA_TUSERDATA || [(NSNumber*)rule intValue] == _scheme.LuaTypeAny)) {
					o = [[LuaLightuserdata alloc] init:lua_touserdata(L, index)];
				}
				break;
			case LUA_TFUNCTION:
				if ([rule isKindOfClass:[NSNumber class]] && ([(NSNumber*)rule intValue] == LUA_TFUNCTION || [(NSNumber*)rule intValue] == _scheme.LuaTypeAny)) {
					o = @([LuaUtils newRef:L index:index]);
				} else if ([rule isKindOfClass:[NSArray class]]) {
					NSArray* ruleArray = (NSArray*) rule;
					if ([(NSString*)ruleArray[0] isEqualToString:@"listener"]) {
						o = @([LuaUtils newRef:L index:index]);
					}
				}
				break;
			case LUA_TTABLE:
				if ([rule isKindOfClass:[NSNumber class]] && [(NSNumber*)rule intValue] == LUA_TTABLE) {
					o = [self toHashtable:L index:index pathList:pathList];
				} else if ([rule isKindOfClass:[NSArray class]]) {
					NSArray* ruleArray = (NSArray*) rule;
					if ([(NSString*)ruleArray[0] isEqualToString:@"listener"] && CoronaLuaIsListener(L, index, [(NSString*)ruleArray[1] UTF8String])) {
						o = @([LuaUtils newRef:L index:index]);
					}
				}
		}
	}
	return o;
}

-(NSMutableDictionary*)toHashtable:(lua_State*)L index:(int)index pathList:(NSMutableArray*)pathList {
	if ((index < 0) && (index > LUA_REGISTRYINDEX)) {
		index = lua_gettop(L) + index + 1;
	}

	NSMutableDictionary* result = [NSMutableDictionary dictionary];
	luaL_checktype(L, index, LUA_TTABLE);
	lua_pushnil(L);

	NSMutableArray* path = pathList != nil ? pathList : [NSMutableArray array];
	for (; lua_next(L, index); lua_pop(L, 1)) {
		id key = nil;
		if (lua_type(L, -2) == LUA_TSTRING) {
			key = @(lua_tostring(L, -2));
			[path addObject:(NSString*)key];
		} else if (lua_type(L, -2) == LUA_TNUMBER) {
			key = @(lua_tointeger(L, -2));
			[path addObject:@"#"];
		}
		if (key != nil) {
			id value = [self toValue:L index:-1 pathList:path];
			if (value != nil) {
				[result setObject:value forKey:key];
			}
			[path removeObjectAtIndex:[path count] - 1];
		}
	}

	return result;
}
@end

@implementation Scheme {
	NSMutableDictionary* scheme;
}

-(id)init {
	self = [super init];
	scheme = [NSMutableDictionary dictionary];
	_LuaTypeNumeric = 1000;
	_LuaTypeByteArray = 1001;
	_LuaTypeAny = 1002;
	return self;
}

-(void)any:(NSString*)path {
	[scheme setObject:@(_LuaTypeAny) forKey:path];
}

-(void)string:(NSString*)path {
	[scheme setObject:@LUA_TSTRING forKey:path];
}

-(void)number:(NSString*)path {
	[scheme setObject:@LUA_TNUMBER forKey:path];
}

-(void)boolean:(NSString*)path {
	[scheme setObject:@LUA_TBOOLEAN forKey:path];
}

-(void)table:(NSString*)path {
	[scheme setObject:@LUA_TTABLE forKey:path];
}

-(void)function:(NSString*)path {
	[scheme setObject:@LUA_TFUNCTION forKey:path];
}

-(void)listener:(NSString*)path {
	[self listener:path name:[[path componentsSeparatedByString:@"."] lastObject]];
}

-(void)listener:(NSString*)path name:(NSString*)eventName {
	[scheme setObject:@[@"listener", eventName] forKey:path];
}

-(void)lightuserdata:(NSString*)path {
	[scheme setObject:@LUA_TLIGHTUSERDATA forKey:path];
}

-(void)userdata:(NSString*)path {
	[scheme setObject:@LUA_TUSERDATA forKey:path];
}

-(void)numeric:(NSString*)path {
	[scheme setObject:@(_LuaTypeNumeric) forKey:path];
}

-(void)byteArray:(NSString*)path {
	[scheme setObject:@(_LuaTypeByteArray) forKey:path];
}

-(id)get:(NSString*)path {
	return [scheme objectForKey:path];
}

@end
