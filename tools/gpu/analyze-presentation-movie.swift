// Sample the displayed guest region of a screencapture movie, excluding host chrome.
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
var frames = 0, almostBlack = 0, run = 0, maxRun = 0
while let sample = output.copyNextSampleBuffer(), let pixels = CMSampleBufferGetImageBuffer(sample) {
 CVPixelBufferLockBaseAddress(pixels, .readOnly)
 let width=CVPixelBufferGetWidth(pixels),height=CVPixelBufferGetHeight(pixels),row=CVPixelBufferGetBytesPerRow(pixels)
 let base=CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
 var dark=0,count=0
 for y in stride(from: min(80,height/4), to:height-12, by:16) {
  for x in stride(from:12,to:width-12,by:16) {
   let offset=y*row+x*4
   count+=1
   if base[offset]<4 && base[offset+1]<4 && base[offset+2]<4 {dark+=1}
  }
 }
 let ratio=Double(dark)/Double(max(count,1))
 if ratio>0.98 {almostBlack+=1;run+=1;maxRun=max(maxRun,run);print("BLACK t=\(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))) fraction=\(ratio)")}
 else {run=0}
 frames+=1
 CVPixelBufferUnlockBaseAddress(pixels,.readOnly)
}
print("MOVIE frames=\(frames) almostEntirelyBlack=\(almostBlack) longestBlackRun=\(maxRun) status=\(reader.status.rawValue)")
