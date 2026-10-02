// Identical offscreen WebGL2 workload for native Chrome and Bromure.
// A synchronous 1-pixel readback forces completion; this is not a GPU timer.
(() => {
  const canvas = document.createElement('canvas');
  const gl = canvas.getContext('webgl2', {antialias:false, preserveDrawingBuffer:false});
  if (!gl) throw Error('WebGL2 unavailable');
  function shader(type, source) {
    const s = gl.createShader(type); gl.shaderSource(s,source); gl.compileShader(s);
    if (!gl.getShaderParameter(s,gl.COMPILE_STATUS)) throw Error(gl.getShaderInfoLog(s));
    return s;
  }
  const vertex = shader(gl.VERTEX_SHADER, `#version 300 es
    layout(location=0) in vec2 position;
    void main() { gl_Position = vec4(position,0.0,1.0); }`);
  const vertices=gl.createBuffer();gl.bindBuffer(gl.ARRAY_BUFFER,vertices);
  gl.bufferData(gl.ARRAY_BUFFER,new Float32Array([-1,-1,3,-1,-1,3]),gl.STATIC_DRAW);
  gl.enableVertexAttribArray(0);gl.vertexAttribPointer(0,2,gl.FLOAT,false,0,0);
  const cases = [
    {name:'draw_calls',width:64,height:64,iterations:4,draws:2048},
    {name:'720p_fill',width:1280,height:720,iterations:32,draws:64},
    {name:'1080p_shader',width:1920,height:1080,iterations:128,draws:24}
  ];
  const prepared = cases.map(c => {
    const fragment = shader(gl.FRAGMENT_SHADER, `#version 300 es
      precision highp float; uniform float phase; out vec4 colour;
      void main() {
        vec3 v = vec3(gl_FragCoord.xy / vec2(${c.width}.0,${c.height}.0),phase);
        for (int i=0;i<${c.iterations};i++) {
          v = fract(v*vec3(1.31,1.57,1.73)+sin(v.yzx+float(i)*0.013)*0.05+0.17);
        }
        colour = vec4(v,0.5);
      }`);
    const program = gl.createProgram(); gl.attachShader(program,vertex); gl.attachShader(program,fragment);
    gl.linkProgram(program); if (!gl.getProgramParameter(program,gl.LINK_STATUS)) throw Error(gl.getProgramInfoLog(program));
    const texture = gl.createTexture(); gl.bindTexture(gl.TEXTURE_2D,texture);
    gl.texStorage2D(gl.TEXTURE_2D,1,gl.RGBA8,c.width,c.height);
    const fbo=gl.createFramebuffer(); gl.bindFramebuffer(gl.FRAMEBUFFER,fbo);
    gl.framebufferTexture2D(gl.FRAMEBUFFER,gl.COLOR_ATTACHMENT0,gl.TEXTURE_2D,texture,0);
    if(gl.checkFramebufferStatus(gl.FRAMEBUFFER)!==gl.FRAMEBUFFER_COMPLETE) throw Error('Incomplete framebuffer');
    gl.clearColor(1,0,0,1); gl.clear(gl.COLOR_BUFFER_BIT);
    const pixel=new Uint8Array(4);gl.readPixels(0,0,1,1,gl.RGBA,gl.UNSIGNED_BYTE,pixel);
    if(String(pixel)!=='255,0,0,255') throw Error('Framebuffer pixel check failed');
    return {...c,program,fbo,phase:gl.getUniformLocation(program,'phase')};
  });
  const run = (name) => {
    const c=prepared.find(c=>c.name===name); if(!c)throw Error('Unknown workload');
    gl.bindFramebuffer(gl.FRAMEBUFFER,c.fbo);gl.viewport(0,0,c.width,c.height);gl.useProgram(c.program);
    gl.enable(gl.BLEND);gl.blendFuncSeparate(gl.SRC_ALPHA,gl.ONE_MINUS_SRC_ALPHA,gl.ONE,gl.ONE_MINUS_SRC_ALPHA);
    gl.disable(gl.DEPTH_TEST);gl.disable(gl.SCISSOR_TEST);gl.clearColor(1,0,0,1);gl.clear(gl.COLOR_BUFFER_BIT);
    for(let i=0;i<8;i++){gl.uniform1f(c.phase,i/8);gl.drawArrays(gl.TRIANGLES,0,3);}
    const pixel=new Uint8Array(4);gl.readPixels(0,0,1,1,gl.RGBA,gl.UNSIGNED_BYTE,pixel);
    const start=performance.now();
    for(let i=0;i<c.draws;i++){gl.uniform1f(c.phase,(i%97)/97);gl.drawArrays(gl.TRIANGLES,0,3);
    }
    gl.readPixels(0,0,1,1,gl.RGBA,gl.UNSIGNED_BYTE,pixel);
    const elapsedMs=performance.now()-start;
    const error=gl.getError();if(error!==0||pixel[3]!==255)throw Error(JSON.stringify({error,pixel:Array.from(pixel)}));
    return {name,width:c.width,height:c.height,iterations:c.iterations,draws:c.draws,elapsedMs,
      drawsPerSecond:c.draws*1000/elapsedMs,pixel:Array.from(pixel),error};
  };
  window.bromureBenchmark = run;
  const debug=gl.getExtension('WEBGL_debug_renderer_info');
  return {webgl2:true,renderer:debug?gl.getParameter(debug.UNMASKED_RENDERER_WEBGL):gl.getParameter(gl.RENDERER),
    gpuTimerAvailable:!!gl.getExtension('EXT_disjoint_timer_query_webgl2'),cases};
})()
