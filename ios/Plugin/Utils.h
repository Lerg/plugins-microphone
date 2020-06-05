#ifndef Utils_h
#define Utils_h

#import "LuaUtils.h"

@interface Utils : LuaUtils

+(int)clamp:(int)value min:(int)min max:(int)max;
+(double)clampDouble:(double)value min:(double)min max:(double)max;

@end

#endif
