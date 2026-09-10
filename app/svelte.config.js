import adapter from '@sveltejs/adapter-node';

/** @type {import('@sveltejs/kit').Config} */
const config = {
	compilerOptions: {
		runes: true
	},
	kit: {
		adapter: adapter(),
		experimental: {
			instrumentation: { server: true },
			tracing: { server: true }
		}
	}
};

export default config;
