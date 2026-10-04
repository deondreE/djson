import {describe, it, expect, beforeAll } from "vitest";
import { DjsonLoader, DjsonDocument } from "./index";
import path from "path";

describe('DJSON WASM Integration', () => {
    let loader: DjsonLoader; 

    beforeAll(async () => {
        loader = await DjsonLoader.load(path.resolve(__dirname, "djson.wasm")); 
    });

    it('should parse basic key-value pairs', () => {
        const input = `
            version = 1
            port = 8080
        `;
        const doc = loader.parse(input);

        expect(doc.getInt("version")).toBe(1);
        expect(doc.getInt("port")).toBe(8080);

        doc.dispose();
    });

    it('shoud handle nested objects via path syntax', () => {
        const input = `
            server = {
                config = {
                    max_users = 5000
                }
            }
        `;
        const doc = loader.parse(input);

        expect(doc.getInt("server.config.max_users")).toBe(5000);
        doc.dispose();
    });

     it('should handle array indexing in paths', () => {
        const input = `
            indices = { 10, 20, 30 }
            matrix = [[1, 2], [3, 4]]
        `;
        const doc = loader.parse(input);
        
        expect(doc.getInt("indices[0]")).toBe(10);
        expect(doc.getInt("indices[1]")).toBe(20);
        expect(doc.getInt("matrix[1][0]")).toBe(3);
        
        doc.dispose();
    });

    it('should return null for missing keys or wrong types', () => {
        const input = `
            name = "Apollo"
            active = true
            val = 42
        `;
        const doc = loader.parse(input);
        
        // Exists but is a string, not an int
        expect(doc.getInt("name")).toBeNull();
        // Exists but is a bool
        expect(doc.getInt("active")).toBeNull();
        // Does not exist
        expect(doc.getInt("nonexistent")).toBeNull();
        
        doc.dispose();
    });

    it('should handle large integers correctly (i64 boundary)', () => {
        // Testing a number larger than 32-bit but within JS safe integer range (2^53 - 1)
        const largeInt = 9007199254740991; 
        const input = `value = ${largeInt}`;
        const doc = loader.parse(input);
        
        expect(doc.getInt("value")).toBe(largeInt);
        doc.dispose();
    });

    it('should permit multiple concurrent documents', () => {
        const doc1 = loader.parse("a = 1");
        const doc2 = loader.parse("a = 2");
        
        expect(doc1.getInt("a")).toBe(1);
        expect(doc2.getInt("a")).toBe(2);
        
        doc1.dispose();
        doc2.dispose();
    });

    describe('Type System (Lazy Access)', () => {
        it('should report correct types for various DJSON values', () => {
            const input = `
                a_null = null
                a_bool = true
                a_int = 42
                a_float = 3.14
                a_string = hello
                a_array = { 1, 2 }
                a_object = { .x = 1 }
            `;
            const doc = loader.parse(input);

            expect(doc.getType("a_null")).toBe("null");
            expect(doc.getType("a_bool")).toBe("bool");
            expect(doc.getType("a_int")).toBe("int");
            expect(doc.getType("a_float")).toBe("float");
            expect(doc.getType("a_string")).toBe("string");
            expect(doc.getType("a_array")).toBe("array");
            expect(doc.getType("a_object")).toBe("object");
            expect(doc.getType("missing")).toBe("undefined");

            doc.dispose();
        });

        it('should navigate types through paths', () => {
            const doc = loader.parse("nested = { list = { { .val = 1 } } }");
            expect(doc.getType("nested.list[0].val")).toBe("int");
            doc.dispose();
        });
    });

    describe('Error Diagnostics', () => {
        it('should provide specific error messages and coordinates', () => {
            const invalidInput = `
                name = "Apollo"
                broken_key  # missing separator
                next = 1
            `;

            try {
                loader.parse(invalidInput);
                expect.fail("Should have thrown a parse error");
            } catch (e: any) {
                const err = e.message;
                // Verify we are no longer just getting "DJSON_PARSE_ERROR"
                expect(err).toContain("DJSON Parse Error");
                // expect(err).toContain("expected '=' or ':'"); // Zig diagnostic message
                expect(err).toMatch(/\d+:\d+/); // Contains line:col
            }
        });

        it('should handle duplicate key errors', () => {
            const input = "key = 1\nkey = 2";
            expect(() => loader.parse(input)).toThrow(/duplicate key/i);
        });
    });

    describe('Performance & Caching', () => {
        it('should return cached values for repeated lookups', () => {
            const doc = loader.parse("score = 100");
            
            // First lookup (goes to WASM)
            const first = doc.getInt("score");
            expect(first).toBe(100);

            // Second lookup (hits TS Map)
            const second = doc.getInt("score");
            expect(second).toBe(100);

            // We can't easily "see" the cache hit without spying on wasm exports,
            // but we verify functional parity.
            doc.dispose();
        });
    });

    it('should stay functional with extremely deep paths', () => {
        // Test tokenization of complex path
        const input = "a = { b = { c = { d = 99 } } }";
        const doc = loader.parse(input);
        expect(doc.getInt("a.b.c.d")).toBe(99);
        doc.dispose();
    });
});