import { defineConfig, type Plugin } from 'vite';
import { resolve } from 'path';
import ts from 'typescript';

// webOS 3.x ships Node 0.12, which only parses ES5, and Rolldown cannot lower
// that far. TypeScript can, so it rewrites the finished bundle once
// minification is done. Node 0.12 has Symbol.iterator, so downlevelIteration
// keeps for-of over Map and Set correct.
function lowerToEs5(): Plugin {
  return {
    name: 'lower-to-es5',
    generateBundle(_options, bundle) {
      for (const output of Object.values(bundle)) {
        if (output.type !== 'chunk') {
          continue;
        }
        const result = ts.transpileModule(output.code, {
          compilerOptions: {
            target: ts.ScriptTarget.ES5,
            module: ts.ModuleKind.CommonJS,
            downlevelIteration: true,
          },
          reportDiagnostics: true,
        });
        if (result.diagnostics && result.diagnostics.length > 0) {
          this.error(ts.flattenDiagnosticMessageText(result.diagnostics[0].messageText, '\n'));
        }
        output.code = result.outputText;
      }
    },
  };
}

export default defineConfig({
  plugins: [lowerToEs5()],
  build: {
    target: 'es2015',
    outDir: resolve(process.cwd(), 'dist'),
    emptyOutDir: true,
    lib: {
      entry: resolve(process.cwd(), 'src/index.ts'),
      formats: ['cjs'],
      fileName: () => 'nospy-dns-filter.js',
    },
    rollupOptions: {
      external: [
        'dgram',
        'dns',
        'fs',
        'net',
      ],
    },
  },
});
