(async () => {
  document.body.style.cssText='margin:0;overflow:hidden;background:#111';
  const canvas=document.createElement('canvas');canvas.width=1920;canvas.height=1080;
  canvas.style.cssText='width:100vw;height:100vh;display:block';document.body.replaceChildren(canvas);
  const gl=canvas.getContext('webgl2',{antialias:false});if(!gl)throw Error('No WebGL2');
  const compile=(type,source)=>{const s=gl.createShader(type);gl.shaderSource(s,source);gl.compileShader(s);if(!gl.getShaderParameter(s,gl.COMPILE_STATUS))throw Error(gl.getShaderInfoLog(s));return s;};
  const program=gl.createProgram();
  gl.attachShader(program,compile(gl.VERTEX_SHADER,'#version 300 es\nvoid main(){vec2 p=vec2((gl_VertexID<<1)&2,gl_VertexID&2);gl_Position=vec4(p*2.-1.,0.,1.);}'));
  gl.attachShader(program,compile(gl.FRAGMENT_SHADER,'#version 300 es\nprecision highp float;uniform float t;out vec4 c;void main(){vec2 p=gl_FragCoord.xy/vec2(1920.,1080.);float wave=sin(p.x*35.+t*3.)*cos(p.y*21.-t*2.);c=vec4(.35+.3*sin(t+p.x*9.),.4+.3*wave,.6+.3*cos(t+p.y*8.),1.);}'));
  gl.linkProgram(program);if(!gl.getProgramParameter(program,gl.LINK_STATUS))throw Error(gl.getProgramInfoLog(program));gl.useProgram(program);
  gl.viewport(0,0,1920,1080);const location=gl.getUniformLocation(program,'t');
  const times=[];let last=null,start=null,hiddenDuringTest=document.hidden,geometryChanged=false;const initial={width:innerWidth,height:innerHeight,dpr:devicePixelRatio};const onVisibility=()=>{hiddenDuringTest ||= document.hidden;};document.addEventListener('visibilitychange',onVisibility);
  await new Promise(resolve=>{function frame(now){geometryChanged ||= innerWidth!==initial.width||innerHeight!==initial.height||devicePixelRatio!==initial.dpr;if(start===null)start=now;if(last!==null&&now-start>3000)times.push(now-last);last=now;gl.uniform1f(location,now/1000);gl.drawArrays(gl.TRIANGLES,0,3);if(now-start<33000)requestAnimationFrame(frame);else resolve();}requestAnimationFrame(frame);});
  document.removeEventListener('visibilitychange',onVisibility);const sorted=times.slice().sort((a,b)=>a-b),percentile=p=>sorted[Math.min(sorted.length-1,Math.floor(sorted.length*p))];
  return {hiddenDuringTest,geometryChanged,frames:times.length,elapsedMs:times.reduce((a,b)=>a+b,0),meanIntervalMs:times.reduce((a,b)=>a+b,0)/times.length,p50IntervalMs:percentile(.5),p95IntervalMs:percentile(.95),p99IntervalMs:percentile(.99),intervalsMs:times,visibility:document.visibilityState,glError:gl.getError(),canvas:{width:canvas.width,height:canvas.height},viewport:{width:innerWidth,height:innerHeight,dpr:devicePixelRatio}};
})()
