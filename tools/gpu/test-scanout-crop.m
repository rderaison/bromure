#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <IOSurface/IOSurface.h>
extern int renderer_capture_surface_region(void *,uint32_t,uint32_t,uint32_t,uint32_t);
extern IOSurfaceRef renderer_take_surface(void);
int main(void){
 @autoreleasepool {
  id<MTLDevice> device=MTLCreateSystemDefaultDevice();
  MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:96 height:32 mipmapped:NO];
  d.storageMode=MTLStorageModeShared;
  id<MTLTexture> texture=[device newTextureWithDescriptor:d];
  uint8_t pixels[96*32*4];
  for(unsigned y=0;y<32;y++)for(unsigned x=0;x<96;x++){
   unsigned i=(y*96+x)*4;pixels[i]=x>=64?255:0;pixels[i+1]=(x>=32&&x<64)?255:0;pixels[i+2]=x<32?255:0;pixels[i+3]=255;
  }
  [texture replaceRegion:MTLRegionMake2D(0,0,96,32) mipmapLevel:0 withBytes:pixels bytesPerRow:96*4];
  for(unsigned crop=0;crop<3;crop++){
   if(!renderer_capture_surface_region((__bridge void *)texture,crop*32,0,32,32))return 1;
   IOSurfaceRef s=renderer_take_surface();
   if(!s || IOSurfaceGetWidth(s)!=32 || IOSurfaceGetHeight(s)!=32)return 1;
   if(IOSurfaceLock(s,kIOSurfaceLockReadOnly,NULL)!=kIOReturnSuccess)return 1;
   const uint8_t *p=IOSurfaceGetBaseAddress(s);size_t stride=IOSurfaceGetBytesPerRow(s);
   for(unsigned y=0;y<32;y++)for(unsigned x=0;x<32;x++){
    const uint8_t *v=p+y*stride+x*4;
    if(v[0]!=(crop==2?255:0)||v[1]!=(crop==1?255:0)||v[2]!=(crop==0?255:0)||v[3]!=255)return 1;
   }
   IOSurfaceUnlock(s,kIOSurfaceLockReadOnly,NULL);CFRelease(s);
  }
  puts("SCANOUT_DISTINCT_CROP_PIXELS_PASS");return 0;
 }
}
