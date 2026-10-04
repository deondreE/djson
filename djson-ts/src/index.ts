type DjsonType = 'null' | 'bool' | 'int' | 'float' | 'string' | 'array' | 'object' | 'undefined';

const TypeMap: Record<number, DjsonType> = {
    [-1]: 'undefined', 0: 'null', 1: 'bool', 2: 'int', 
    3: 'float', 4: 'string', 5: 'array', 6: 'object'
};

interface DjsonWasmExports extends WebAssembly.Exports {
    memory: WebAssembly.Memory;
    alloc: (len: number) => number;
    free: (ptr: number, len: number) => void;
    djson_parse_buf: (ptr: number, len: number) => number;
    djson_free: (handle: number) => void;
    djson_get_int: (handle: number, pPtr: number, pLen: number, oPtr: number) => boolean;
    djson_get_type: (handle: number, pPtr: number, pLen: number) => number;
    djson_err_msg_ptr: () => number;
    djson_err_msg_len: () => number;
    djson_err_line: () => number;
    djson_err_col: () => number;
}

export class DjsonDocument {
    private intCache = new Map<string, number>();

    constructor(
        private wasm: DjsonWasmExports,
        private handle: number
    ) {}
   
    public getType(path: string): DjsonType {
        return this.withPath(path, (ptr, len) => {
            const typeId = this.wasm.djson_get_type(this.handle, ptr, len);
            return TypeMap[typeId] || 'undefined';
        });
    }

    /**
     * Queries an integer using a path like "server.port" or "users[0].id"
     */
     getInt(path: string): number | null {
        if (this.intCache.has(path)) return this.intCache.get(path)!;

        return this.withPath(path, (ptr, len) => {
            const outPtr = this.wasm.alloc(8);
            const success = this.wasm.djson_get_int(this.handle, ptr, len, outPtr);

            let result: number | null = null;
            if (success) {
                // Must access buffer AFTER all allocations to handle memory growth
                const outView = new BigInt64Array(this.wasm.memory.buffer, outPtr, 1);
                result = Number(outView[0]);
                this.intCache.set(path, result);
            }

            this.wasm.free(outPtr, 8);
            return result;
        });
    }

    /**
     * Internal helper to safely pass strings to WASM and ensure cleanup
     */
    private withPath<T>(path: string, fn: (ptr: number, len: number) => T): T {
        const encoder = new TextEncoder();
        const encoded = encoder.encode(path);
        const ptr = this.wasm.alloc(encoded.length);
        
        // Re-create view from memory.buffer immediately before write
        new Uint8Array(this.wasm.memory.buffer, ptr, encoded.length).set(encoded);

        try {
            return fn(ptr, encoded.length);
        } finally {
            this.wasm.free(ptr, encoded.length);
        }
    }

    dispose(): void {
        if (this.handle !== 0) {
            this.wasm.djson_free(this.handle);
            this.handle = 0;
            this.intCache.clear();
        }
    }
}

export class DjsonLoader {
    private wasm: DjsonWasmExports;

    constructor(instance: WebAssembly.Instance) {
        this.wasm = instance.exports as DjsonWasmExports;
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
        new Uint8Array(this.wasm.memory.buffer, ptr, encoded.length).set(encoded);

        const handle = this.wasm.djson_parse_buf(ptr, encoded.length);
        this.wasm.free(ptr, encoded.length);

        if (handle === 0) {
            const msgPtr = this.wasm.djson_err_msg_ptr();
            const msgLen = this.wasm.djson_err_msg_len();
            const line = this.wasm.djson_err_line();
            const col = this.wasm.djson_err_col();

            const msg = new TextDecoder().decode(
                new Uint8Array(this.wasm.memory.buffer, msgPtr, msgLen)
            );
            // Standardize this string so the test expectation matches
            throw new Error(`DJSON Parse Error at ${line}:${col}: ${msg}`);
        }
        
        return new DjsonDocument(this.wasm, handle); 
    }
}
