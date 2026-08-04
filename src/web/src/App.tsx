import React, { useEffect, useRef, useState } from 'react';
import * as THREE from 'three';

interface AttractorData {
	id: string;
	formulaLatex: string;
	rSquared: number;
	isStable: boolean;
	createdAt: string;
}

export const App: React.FC = () => {
	const [attractor, setAttractor] = useState<AttractorData | null>(null);
	const [isConnected, setIsConnected] = useState<boolean>(false);
	const mountRef = useRef<HTMLDivElement>(null);

	useEffect(() => {
		const ws = new WebSocket('ws://localhost:5236/ws');

		ws.onopen = () => {
			console.log('[Web] Connected to C# Gateway WebSocket');
			setIsConnected(true);
		};

		ws.onmessage = (event) => {
			try {
				const message = JSON.parse(event.data);
				if (message.type === 'ATTRACTOR_UPDATED' && message.data)  {
					setAttractor(message.data);
				}
			} catch (err) {
				console.error('[Web] Failed to parse WebSocket message:', err);
			}
		};

		ws.onclose = () => {
			console.log('[Web] WebSocket disconnected');
			setIsConnected(false);
		};

		return () => {
			ws.close();
		};
	}, []);

	useEffect(() => {
		if (!mountRef.current) {
			return;
		}

		const width = mountRef.current.clientWidth;
		const height = mountRef.current.clientHeight;

		const scene = new THREE.Scene();
		scene.background = new THREE.Color(0x0a0a0f);

		const camera = new THREE.PerspectiveCamera(75, width / height, 0.1, 1000);
		camera.position.z = 30;

		const renderer = new THREE.WebGLRenderer({ antialias: true });
		renderer.setSize(width, height);
		mountRef.current.appendChild(renderer.domElement);

		const particleCount = 2000;
		const geometry = new THREE.BufferGeometry();
		const position = new Float32Array(particleCount * 3);

		for (let i = 0; i < particleCount * 3; i += 3) {
			position[i] = (Math.random() - 0.5) * 40;
			position[i + 1] = (Math.random() - 0.5) * 40;
			position[i + 2] = (Math.random() - 0.5) * 40;
		}

		geometry.setAttribute('position', new THREE.BufferAttribute(position, 3));
		const material = new THREE.PointsMaterial({
			color: 0x6366f1,
			size: 0.5,
			transparent: true,
			opacity: 0.8,
		});

		const particles = new THREE.Points(geometry, material);
		scene.add(particles);

		let animationFrameId: number;
		const animate = () => {
			animationFrameId = requestAnimationFrame(animate);
			particles.rotation.x += 0.001;
			particles.rotation.y += 0.002;
			renderer.render(scene, camera);
		};
		animate();

		const handleResize = () => {
			if (!mountRef.current) {
				return;
			}
			const w = mountRef.current.clinetWidth;
			const h = mountRef.current.clientHeight;
			camera.aspect = w / h;
			camera.updateProjectionMatrix();
			renderer.setSize(w, h);
		};

		window.addEventListener('resize', handleResize);

		return () => {
			cancelAnimatioonFrame(animationFrameId);
			window.removeEventListener('resize', handleResize);
			if (mountRef.current) {
				mountRef.current.removeChild(renderer.domElement);
			}
		};
	}, []);

	return (
		<div>
			<div ref={mountRef} />
			<div>
				<div>
					<h2>A P E I R O N</h2>
					<span>
						{isConnected ? 'LIVE WS' : 'DISCONNECTED'}
					</span>
				</div>

				{attractor ? (
					<div>
						<div>
						<div>
							{attractor.formulaLatex}
						</div>

						<div>
							<span>Fit Score (R^2):</span>
							<strong>
								{(attractor.rSquared * 100).toFixed(2)}%
							</strong>
						</div>

						<div>
							<span>State:</span>
							<span>
								{attractor.isStable ? 'LAMINAR / STABLE' : 'TURBULENT / LIMINAL'}
							</span>
						</div>
					</div>
				) : (
					<div>
						Waiting for live stream attractor calculation...
					</div>
				)}
			</div>
		</div>
	);
};

