#import <CoronaApplicationMain.h>
#import "AppCoronaDelegate.h"

int main(int argc, char *argv[]) {
	@autoreleasepool {
		CoronaApplicationMain(argc, argv, [AppCoronaDelegate class]);
	}
	return 0;
}
