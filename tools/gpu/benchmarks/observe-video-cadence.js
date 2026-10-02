/* Diagnostic Runtime.evaluate expression with awaitPromise=true, returnByValue=true.
 * Use a selected existing page target and a 15s CDP wall timeout. Does not start,
 * stop, seek, focus, navigate, draw or change page/video settings. 10s only.
 * Counts JS/compositor notifications, NOT physical host display refresh. */
(() => new Promise((resolve, reject) => {
  const videos = [...document.querySelectorAll('video')];
  if (videos.length !== 1) { reject(new Error('Expected exactly one video in selected page; found '+videos.length)); return; }
  const v = videos[0], start = performance.now(), wallStart = Date.now();
  if (!v.requestVideoFrameCallback) { reject(new Error('requestVideoFrameCallback unavailable')); return; }
  let raf = 0, vf = 0, done = false, lastR = null, lastV = null, lastPresented = null;
  const rIntervals=[], vIntervals=[], processing=[], first50=[], after50=[], visibility=[];
  let rCount=0, vCount=0, presentedDelta=0, callbackGaps=0;
  function state() { const q=v.getVideoPlaybackQuality(); return {
    currentTime:v.currentTime, paused:v.paused, readyState:v.readyState,
    width:v.videoWidth,height:v.videoHeight,playbackRate:v.playbackRate,
    total:q.totalVideoFrames,dropped:q.droppedVideoFrames, visibility:document.visibilityState,
    viewport:[innerWidth,innerHeight],dpr:devicePixelRatio,error:v.error?.code ?? null}; }
  const before=state();
  function summary(a) { const sorted=[...a].sort((a,b)=>a-b); return {
    count:a.length,p50:sorted[Math.floor(sorted.length*.5)]??null,
    p95:sorted[Math.min(sorted.length-1,Math.floor(sorted.length*.95))]??null,
    max:sorted.at(-1)??null,over25ms:a.filter(x=>x>25).length,over40ms:a.filter(x=>x>40).length}; }
  function onR(now) { if(done)return; if(lastR!==null && rIntervals.length<6000)rIntervals.push(now-lastR); lastR=now;rCount++;raf=requestAnimationFrame(onR); }
  function onV(now,m) { if(done)return;vCount++;
    if(lastV!==null && vIntervals.length<6000){const dt=now-lastV;vIntervals.push(dt);(vCount<=50?first50:after50).push(dt);}lastV=now;
    if(lastPresented!==null){presentedDelta+=m.presentedFrames-lastPresented;callbackGaps+=Math.max(0,m.presentedFrames-lastPresented-1);}lastPresented=m.presentedFrames;
    if(Number.isFinite(m.processingDuration)&&processing.length<6000)processing.push(m.processingDuration*1000);
    vf=v.requestVideoFrameCallback(onV);
  }
  function onVisibility(){if(visibility.length<100)visibility.push({ms:performance.now()-start,state:document.visibilityState});}
  document.addEventListener('visibilitychange',onVisibility);
  raf=requestAnimationFrame(onR);vf=v.requestVideoFrameCallback(onV);
  setTimeout(()=>{done=true;cancelAnimationFrame(raf);v.cancelVideoFrameCallback(vf);document.removeEventListener('visibilitychange',onVisibility);
    const elapsed=performance.now()-start, after=state();resolve({scope:'existing one-video page; callbacks not physical display',wallStart,elapsedMs:elapsed,before,after,
      rafCallbacks:rCount,videoCallbacks:vCount,rafHz:rCount*1000/elapsed,videoCallbackHz:vCount*1000/elapsed,
      mediaSecondsAdvanced:after.currentTime-before.currentTime,totalFramesDelta:after.total-before.total,droppedFramesDelta:after.dropped-before.dropped,
      presentedDelta,callbackGaps,rafIntervalsMs:summary(rIntervals),videoIntervalsMs:summary(vIntervals),
      first50VideoIntervalsMs:summary(first50),laterVideoIntervalsMs:summary(after50),processingDurationMs:summary(processing),visibility});
  },10000);
}))()
