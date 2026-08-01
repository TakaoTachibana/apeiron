import { defineConfig } from '@rsbuild/core';
import { pluginReact } from '@rsbuild/plugin-react';

export default defineConfig({
	plygins: [pluginReact()],
	html: {
		title: 'Apeiron - Autopoietic Phase-Space Platform',
	},
});

