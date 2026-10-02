#import <Foundation/Foundation.h>
#import <IOSurface/IOSurface.h>
#import <IOSurface/IOSurfaceObjC.h>

@protocol BromureRendererService
- (void)processCommand:(NSData *)command
                 reply:(void (^)(NSData *response, IOSurface *surface, NSError *error))reply;
@end
