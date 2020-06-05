#import <Foundation/Foundation.h>
#import "CoronaAssert.h"
#import "Utils.h"

@implementation Utils : LuaUtils

+(int)clamp:(int)value min:(int)min max:(int)max {
    if (value > max) {
        return max;
    } else if (value < min) {
        return min;
    } else {
        return value;
    }
}

+(double)clampDouble:(double)value min:(double)min max:(double)max {
    if (value > max) {
        return max;
    } else if (value < min) {
        return min;
    } else {
        return value;
    }
}

@end
