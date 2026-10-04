interface DjsonWasmExports extends WebAssembly.Exports {
    memory: WebAssembly.Memory;
    alloc: (len: number) => number;
    free: (ptr: number, len: number) => void;
    djson_parse_buf: (ptr: number, len: number) => number;
    djson_free: (handle: number) => void;
    djson_get_int: (handle: number, pathPtr: number, pathLen: number, outPtr: number) => boolean;
}

export class DjsonDocument {
    constructor(
        private wasm: DjsonWasmExports,
        private handle: number
    ) {}
   
    /**
     * Queries an integer using a path like "server.port" or "users[0].id"
     */
     getInt(path: string): number | null {
        const encoder = new TextEncoder();
        const encodedPath = encoder.encode(path);
        
        const pathPtr = this.wasm.alloc(encodedPath.length);
        new Uint8Array(this.wasm.memory.buffer, pathPtr, encodedPath.length).set(encodedPath);

        const outPtr = this.wasm.alloc(8);
        const success = this.wasm.djson_get_int(this.handle, pathPtr, encodedPath.length, outPtr);

        let result: number | null = null;
        if (success) {
            const outView = new BigInt64Array(this.wasm.memory.buffer, outPtr, 1);
            result = Number(outView[0]);
        }

        this.wasm.free(pathPtr, encodedPath.length);
        this.wasm.free(outPtr, 8);

        return result;
    }

    dispose(): void {
        if (this.handle) {
            this.wasm.djson_free(this.handle);
            this.handle = 0;
        }
    }
}

export class DjsonLoader {
    private wasm: DjsonWasmExports;

    constructor(wasmModule: WebAssembly.Instance) {
        this.wasm = wasmModule.exports as DjsonWasmExports ;
    }
    static async load(wasmSource: BufferSource | string): Promise<DjsonLoader> {
        let source: BufferSource;
        if (typeof wasmSource === 'string') {
            const fs = await import("fs/promises");
            source = await fs.readFile(wasmSource);
        } else {
            source = wasmSource;
        }

        const { instance } = await WebAssembly.instantiate(source);
        return new DjsonLoader(instance);
    }

    parse(source: string): DjsonDocument {
        const encoder = new TextEncoder();
        const encoded = encoder.encode(source);

        const ptr = this.wasm.alloc(encoded.length);
        const mem = new Uint8Array(this.wasm.memory.buffer, ptr, encoded.length);
        mem.set(encoded);

        const handle = this.wasm.djson_parse_buf(ptr, encoded.length);
        this.wasm.free(ptr, encoded.length);

        if (handle === 0) throw new Error("DJSON_PARSE_ERROR");

        return new DjsonDocument(this.wasm, handle); 
    }
}