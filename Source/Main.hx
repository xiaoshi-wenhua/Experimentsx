package;

import gltoolbox.render.RenderTarget;
import haxe.Timer;
import lime.app.Application;
import lime.graphics.opengl.*;
import lime.graphics.GLRenderContext;
import lime.graphics.RenderContext;
import lime.math.Vector2;
import lime.ui.KeyCode;
import lime.utils.Float32Array;
import shaderblox.ShaderBase;

class Main extends Application {
	var gl:GLRenderContext;
	//Simulations
	var fluid:GPUFluid;
	var particles:GPUParticles;
	//Geometry
	var textureQuad:GLBuffer = null; 
	//Framebuffers
	var screenBuffer:GLFramebuffer = null;	//null for all platforms exlcuding ios, where it references the defaultFramebuffer (UIStageView.mm)
	//Render Targets
	var offScreenTarget:RenderTarget;
	//Shaders
	var screenTextureShader   : ScreenTexture;
	var renderParticlesShader : ColorParticleMotion;
	var updateDyeShader       : MouseDye;
	var mouseForceShader      : MouseForce;
	//Window
	var isMouseDown:Bool = false;
	var mousePointKnown:Bool = false;
	var lastMousePointKnown:Bool = false;
	var mouse = new Vector2();
	var mouseClipSpace = new Vector2();
	var lastMouse = new Vector2();
	var lastMouseClipSpace = new Vector2();

	var time:Float;
	var lastTime:Float;

	var renderParticlesEnabled:Bool = true;
	var renderFluidEnabled:Bool = true;

	#if js
	var browserMonitor:BrowserMonitor;
	#end
	
	public function new () {
		super();
				
		#if js
		browserMonitor = new BrowserMonitor(this, 'http://awestronomer.com/services/browser-monitor/');
		browserMonitor.sendReportAfterTime(7);
		#end
	}

	public override function init (context:RenderContext):Void {
		switch (context) {
			case OPENGL (gl):
				this.gl = gl;

				gl.disable(gl.DEPTH_TEST);
				gl.disable(gl.CULL_FACE);
				gl.disable(gl.DITHER);

				#if ios //grab default screenbuffer
				screenBuffer = new GLFramebuffer(gl.version, gl.getParameter(gl.FRAMEBUFFER_BINDING));
				#end
				textureQuad = gltoolbox.GeometryTools.createQuad(gl, 0, 0, 1, 1);

				offScreenTarget = new RenderTarget(gl, 
					gltoolbox.TextureTools.customTextureFactory(
						gl.RGBA,
						gl.UNSIGNED_BYTE,
						gl.NEAREST
					),
					Math.round(window.width/1),
					Math.round(window.height/1)
				);

				screenTextureShader = new ScreenTexture();
				renderParticlesShader = new ColorParticleMotion();
				updateDyeShader = new MouseDye();
				mouseForceShader = new MouseForce();

				updateDyeShader.mouseClipSpace.data = mouseClipSpace;
				updateDyeShader.lastMouseClipSpace.data = lastMouseClipSpace;
				mouseForceShader.mouseClipSpace.data = mouseClipSpace;
				mouseForceShader.lastMouseClipSpace.data = lastMouseClipSpace;

				var scaleFactor = 1/4;
				var fluidIterations = 20;
				var fluidScale = 32;
				var particleCount = 524288;

				#if js
					scaleFactor = 1/4;
					fluidIterations = 18;
				#end
				
				fluid = new GPUFluid(gl, Math.round(window.width*scaleFactor), Math.round(window.height*scaleFactor), fluidScale, fluidIterations);
				fluid.updateDyeShader = updateDyeShader;
				fluid.applyForcesShader = mouseForceShader;

				particles = new GPUParticles(gl, particleCount);
				particles.flowScaleX = fluid.simToClipSpaceX(1);
				particles.flowScaleY = fluid.simToClipSpaceY(1);
				particles.dragCoefficient = 1;

				#if js
				//record supported extensions
				browserMonitor.userData.texture_float_linear = gl.getExtension('OES_texture_float_linear') != null;
				browserMonitor.userData.texture_float = gl.getExtension('OES_texture_float') != null;
				//record settings
				browserMonitor.userData.scaleFactor = scaleFactor;
				browserMonitor.userData.fluidIterations = fluidIterations;
				browserMonitor.userData.fluidScale = fluidScale;
				browserMonitor.userData.particleCount = particleCount;
				//check and halt Safari browser
				if(browserMonitor.isSafari()){
					js.Lib.alert("There's a bug with Safari's GLSL compiler, until I can track down what triggers it, this demo only works in Chrome and Firefox");
					return;
				}
				#end
			default:
				#if js
					js.Lib.alert('WebGL is not supported');
				#end
				trace('RenderContext \'$context\' not supported');
		}

		lastTime = haxe.Timer.stamp();
	}

	public override function render (context:RenderContext):Void {
		time = haxe.Timer.stamp();
		var dt = time - lastTime; //60fps ~ 0.016
		lastTime = time;

		#if js
		browserMonitor.addDt(dt*1000);
		#end

		//update mouse velocity
		if(lastMousePointKnown){
			updateDyeShader.isMouseDown.set(isMouseDown);
			mouseForceShader.isMouseDown.set(isMouseDown);
		}

		//step physics
		fluid.step(dt);

		particles.flowVelocityField = fluid.velocityRenderTarget.readFromTexture;
		if(renderParticlesEnabled) particles.step(dt);

		//render to offScreen
		gl.viewport (0, 0, offScreenTarget.width, offScreenTarget.height);
		gl.bindFramebuffer(gl.FRAMEBUFFER, offScreenTarget.frameBufferObject);
		// gl.viewport (0, 0, window.width, window.height);
		// gl.bindFramebuffer(gl.FRAMEBUFFER, screenBuffer);

		gl.clearColor(0,0,0,1);
		gl.clear(gl.COLOR_BUFFER_BIT);

		// additive blending
		gl.enable(gl.BLEND);
		gl.blendFunc( gl.SRC_ALPHA, gl.SRC_ALPHA );
		gl.blendEquation(gl.FUNC_ADD);

		if(renderParticlesEnabled) renderParticles();
		if(renderFluidEnabled) renderTexture(fluid.dyeRenderTarget.readFromTexture);

		gl.disable(gl.BLEND);

		//render offScreen texture to screen
		gl.viewport (0, 0, window.width, window.height);
		gl.bindFramebuffer(gl.FRAMEBUFFER, screenBuffer);
		renderTexture(offScreenTarget.texture);

		updateLastMouse();
	}

	inline function renderTexture(texture:GLTexture){
		gl.bindBuffer (gl.ARRAY_BUFFER, textureQuad);

		screenTextureShader.texture.data = texture;
		
		screenTextureShader.activate(true, true);
		gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
		screenTextureShader.deactivate();
	}

	inline function renderParticles():Void{
		//set vertices
		gl.bindBuffer(gl.ARRAY_BUFFER, particles.particleUVs);

		//set uniforms
		renderParticlesShader.particleData.data = particles.particleData.readFromTexture;

		//draw points
		renderParticlesShader.activate(true, true);
		//additive blending between particles
		// gl.enable(gl.BLEND);
		// gl.blendFunc( gl.SRC_ALPHA, gl.SRC_ALPHA );
		// gl.blendEquation(gl.FUNC_ADD);

		gl.drawArrays(gl.POINTS, 0, particles.count);

		// gl.disable(gl.BLEND);
		renderParticlesShader.deactivate();
	}

	function reset():Void{
		particles.reset();	
	}

	//coordinate conversion
	inline function windowToClipSpaceX(x:Float)return (x/window.width)*2 - 1;
	inline function windowToClipSpaceY(y:Float)return ((window.height-y)/window.height)*2 - 1;

	override function onMouseDown( x : Float , y : Float , button : Int ){
		this.isMouseDown = true; 
	}
	override function onMouseUp( x : Float , y : Float , button : Int ){
		this.isMouseDown = false;
	}

	override function onMouseMove( x : Float , y : Float , button : Int ) {
		mouse.setTo(x, y);
		mouseClipSpace.setTo(
			windowToClipSpaceX(x),
			windowToClipSpaceY(y)
		);
		mousePointKnown = true;
	}

	inline function updateLastMouse(){
		lastMouse.setTo(mouse.x, mouse.y);
		lastMouseClipSpace.setTo(
			windowToClipSpaceX(mouse.x),
			windowToClipSpaceY(mouse.y)
		);
		lastMousePointKnown = true && mousePointKnown;
	}

	override function onKeyUp( keyCode : Int , modifier : Int ){
		switch (keyCode) {
			case KeyCode.R:
				reset();
			case KeyCode.P:
				renderParticlesEnabled = !renderParticlesEnabled;
			case KeyCode.F:
				renderFluidEnabled = !renderFluidEnabled;
		}
	}
}


@:vert('#pragma include("Source/shaders/glsl/no-transform.vert")')
@:frag('#pragma include("Source/shaders/glsl/quad-texture.frag")')
class ScreenTexture extends ShaderBase {}

@:vert('
	void main(){
		set();

		//generate color
		vec2 v = texture2D(particleData, particleUV).ba;

		float speed = length(v);
		float x = clamp(speed * 4.0, 0., 1.);
		color.rgb = (
				mix(vec3(10.4, 10., 6.0) / 100.0, vec3(0.2, 47.8, 100) / 100.0, x)
				+ (vec3(63.1, 92.5, 100) / 100.) * pow(x, 3.) * .1
		);
		color.a = pow(x, .4);
	}
')
class ColorParticleMotion extends GPUParticles.RenderParticles{}

@:frag('
	#pragma include("Source/shaders/glsl/geom.glsl")

	uniform bool isMouseDown;
	uniform vec2 mouseClipSpace;
	uniform vec2 lastMouseClipSpace;

	void main(){
		color.r *= (0.9797);
		color.g *= (0.9494);
		color.b *= (0.9696);
		if(isMouseDown){			
			vec2 mouse = clipToSimSpace(mouseClipSpace);
			vec2 lastMouse = clipToSimSpace(lastMouseClipSpace);
			vec2 mouseVelocity = -(lastMouse - mouse)*dx/dt;
			
			
			float projection;
			float l = distanceToSegment(mouse, lastMouse, p, projection);
			float taperFactor = 0.6;
			float projectedFraction = 1.0 - clamp(projection / distance(mouse, lastMouse), 0.0, 1.0)*taperFactor;
			float R = 0.025;
			float m = exp(-l/R);
			
 			
 			float speed = length(mouseVelocity);
			float x = clamp((speed * speed * 0.00002 - l * 5.0) * projectedFraction, 0., 1.);
			color.rgb += m * (
				mix(vec3(2.4, 0, 5.9) / 60.0, vec3(0.2, 51.8, 100) / 30.0, x)
 				+ (vec3(100) / 100.) * pow(x, 9.)
			);
		}

		gl_FragColor = color;
	}
')
class MouseDye extends GPUFluid.UpdateDye{}

@:frag('
	#pragma include("Source/shaders/glsl/geom.glsl")

	uniform bool isMouseDown;
	uniform vec2 mouseClipSpace;
	uniform vec2 lastMouseClipSpace;

	void main(){
		v.xy *= 0.999;

		if(isMouseDown){
			vec2 mouse = clipToSimSpace(mouseClipSpace);
			vec2 lastMouse = clipToSimSpace(lastMouseClipSpace);
			vec2 mouseVelocity = -(lastMouse - mouse)*dx/dt;
				
			//compute tapered distance to mouse line segment
			float projection;
			float l = distanceToSegment(mouse, lastMouse, p, projection);
			float taperFactor = 0.6;//1 => 0 at lastMouse, 0 => no tapering
			float projectedFraction = 1.0 - clamp(projection / distance(mouse, lastMouse), 0.0, 1.0)*taperFactor;

			float R = 0.02;
			float m = exp(-l/R); //drag coefficient
			m *= m * projectedFraction * projectedFraction;

			vec2 tv = mouseVelocity;
			// float maxSpeed = 10.04 * dx / dt;
			// tv = clamp(tv, -maxSpeed, maxSpeed); //impose max speed
			v += (tv - v)*m;
		}

		gl_FragColor = vec4(v, 0, 1.);
	}
')
class MouseForce extends GPUFluid.ApplyForces{}