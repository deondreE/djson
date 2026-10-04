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

    it('should throw an error on invalid DJSON syntax', () => {
        const invalidInput = `
            key = { unterminated container
        `;
        
        expect(() => loader.parse(invalidInput)).toThrow("DJSON_PARSE_ERROR");
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
});