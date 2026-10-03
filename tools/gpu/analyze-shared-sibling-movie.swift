// Acceptance for the static blue sibling fixture during shared desktop resize.
// Inspect the central guest region, excluding host chrome and shadow.
// Near-black frames are candidates for manual inspection, not proof of flicker:
// legitimately dark pages/videos can also satisfy this metric.
// Usage: swift analyze-presentation-movie.swift window.mov
import Foundation
import AVFoundation
import CoreVideo
guard CommandLine.arguments.count == 2 else { fatalError("Pass a window movie path") }
let asset = AVURLAsset(url: URL(fileURLWithPath: CommandLine.arguments[1]))
let reader = try AVAssetReader(asset: asset)
let track = asset.tracks(withMediaType: .video).first!
let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
output.alwaysCopiesSampleData = false
reader.add(output)
precondition(reader.startReading())
var frames = 0, almostBlack = 0, run = 0, maxRun = 0, blueFrames = 0
while let sample = output.copyNextSampleBuffer(), let pixels = CMSampleBufferGetImageBuffer(sample) {
 CVPixelBufferLockBaseAddress(pixels, .readOnly)
 let width=CVPixelBufferGetWidth(pixels),height=CVPixelBufferGetHeight(pixels),row=CVPixelBufferGetBytesPerRow(pixels)
 let base=CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
 var dark=0,count=0,blue=0
 for y in stride(from: height/3, to:height*2/3, by:8) {
  for x in stride(from:width/3,to:width*2/3,by:8) {
   let offset=y*row+x*4
   count+=1
   if base[offset]<8 && base[offset+1]<8 && base[offset+2]<8 {dark+=1}
   if base[offset]>100 && base[offset+1]>20 && base[offset+2]<80 {blue+=1}
  }
 }
 let ratio=Double(dark)/Double(max(count,1))
 if Double(blue)/Double(max(count,1))>0.90 {blueFrames+=1}
 if ratio>0.90 {almostBlack+=1;run+=1;maxRun=max(maxRun,run);print("BLACK t=\(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))) fraction=\(ratio)")}
 else {run=0}
 frames+=1
 CVPixelBufferUnlockBaseAddress(pixels,.readOnly)
}
precondition(reader.status == .completed && frames > 100 && almostBlack == 0 && blueFrames == frames, "Blue sibling must remain painted throughout recording")
print("BROMURE_SHARED_SIBLING_MOVIE_PASS blueFrames=\(blueFrames)")
print("MOVIE frames=\(frames) almostEntirelyBlack=\(almostBlack) longestBlackRun=\(maxRun) status=\(reader.status.rawValue)")
