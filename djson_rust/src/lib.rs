use std::ffi::{c_char, c_void};
use std::ptr;

#[repr(C)]
struct RawDjsonHandle(c_void);

#[repr(C)]
struct RawDjsonValue(c_void);

#[repr(C)]
struct RawArrayIter(c_void);

#[repr(C)]
struct RawObjectIter(c_void);

unsafe extern "C" {
    fn djson_parse_buf(ptr: *const u8, len: usize) -> *mut RawDjsonHandle;
    fn djson_free(handle: *mut RawDjsonHandle);
    fn djson_err_msg_ptr() -> *const c_char;
    fn djson_err_msg_len() -> usize;
    fn djson_err_line() -> usize;
    fn djson_err_col() -> usize;

    fn djson_get_value(
        handle: *mut RawDjsonHandle,
        path: *const u8,
        len: usize,
    ) -> *mut RawDjsonValue;
    fn djson_get_int(
        handle: *mut RawDjsonHandle,
        path: *const u8,
        len: usize,
        out: *mut i64,
    ) -> bool;
    fn djson_get_type(handle: *mut RawDjsonHandle, path: *const u8, len: usize) -> i32;

    fn djson_array_iter(val: *mut RawDjsonValue) -> *mut RawArrayIter;
    fn djson_array_next(it: *mut RawArrayIter) -> *mut RawDjsonValue;
    fn djson_array_iter_free(it: *mut RawArrayIter);

    fn djson_object_iter(val: *mut RawDjsonValue) -> *mut RawObjectIter;
    fn djson_object_next(
        it: *mut RawObjectIter,
        key_out: *mut *const u8,
        len_out: *mut usize,
    ) -> *mut RawDjsonValue;
    fn djson_object_iter_free(it: *mut RawObjectIter);
}

pub struct DjsonDocument {
    handle: ptr::NonNull<RawDjsonHandle>,
}

impl DjsonDocument {
    pub fn parse(source: &str) -> Result<Self, String> {
        let handle_ptr = unsafe { djson_parse_buf(source.as_ptr(), source.len()) };

        if let Some(handle) = ptr::NonNull::new(handle_ptr) {
            Ok(Self { handle })
        } else {
            let msg = unsafe {
                let p = djson_err_msg_ptr() as *const u8;
                let l = djson_err_msg_len();
                let slice = std::slice::from_raw_parts(p, l);
                String::from_utf8_lossy(slice)
            };
            Err(format!(
                "Error at {}:{}: {}",
                unsafe { djson_err_line() },
                unsafe { djson_err_col() },
                msg
            ))
        }
    }

    pub fn get_value(&self, path: &str) -> Option<DjsonValue<'_>> {
        let val_ptr = unsafe {
            djson_get_value(self.handle.as_ptr(), path.as_ptr(), path.len())
        };
        ptr::NonNull::new(val_ptr).map(|ptr| DjsonValue {
            ptr,
            _marker: std::marker::PhantomData,
        })
    }

    pub fn get_int(&self, path: &str) -> Option<i64> {
        let mut out = 0i64;
        let found = unsafe {
            djson_get_int(self.handle.as_ptr(), path.as_ptr(), path.len(), &mut out)
        };
        if found {
            Some(out)
        } else {
            None
        }
    }

    pub fn get_type_raw(&self, path: &str) -> i32 {
        unsafe { djson_get_type(self.handle.as_ptr(), path.as_ptr(), path.len()) }
    }
}

impl Drop for DjsonDocument {
    fn drop(&mut self) {
        unsafe { djson_free(self.handle.as_ptr()) }
    }
}

pub struct DjsonValue<'a> {
    ptr: ptr::NonNull<RawDjsonValue>,
    _marker: std::marker::PhantomData<&'a DjsonDocument>,
}

impl<'a> DjsonValue<'a> {
    pub fn array_iter(&self) -> Option<DjsonArrayIter<'a>> {
        let it_ptr = unsafe { djson_array_iter(self.ptr.as_ptr()) };
        ptr::NonNull::new(it_ptr).map(|ptr| DjsonArrayIter {
            ptr,
            _marker: std::marker::PhantomData,
        })
    }

    pub fn object_iter(&self) -> Option<DjsonObjectIter<'a>> {
        let it_ptr = unsafe { djson_object_iter(self.ptr.as_ptr()) };
        ptr::NonNull::new(it_ptr).map(|ptr| DjsonObjectIter {
            ptr,
            _marker: std::marker::PhantomData,
        })
    }
}

pub struct DjsonArrayIter<'a> {
    ptr: ptr::NonNull<RawArrayIter>,
    _marker: std::marker::PhantomData<&'a DjsonDocument>,
}

impl<'a> Iterator for DjsonArrayIter<'a> {
    type Item = DjsonValue<'a>;

    fn next(&mut self) -> Option<Self::Item> {
        let val_ptr = unsafe { djson_array_next(self.ptr.as_ptr()) };
        ptr::NonNull::new(val_ptr).map(|ptr| DjsonValue {
            ptr,
            _marker: std::marker::PhantomData,
        })
    }
}

impl<'a> Drop for DjsonArrayIter<'a> {
    fn drop(&mut self) {
        unsafe { djson_array_iter_free(self.ptr.as_ptr()) }
    }
}

pub struct DjsonObjectIter<'a> {
    ptr: ptr::NonNull<RawObjectIter>,
    _marker: std::marker::PhantomData<&'a DjsonDocument>,
}

impl<'a> Iterator for DjsonObjectIter<'a> {
    type Item = (&'a str, DjsonValue<'a>);

    fn next(&mut self) -> Option<Self::Item> {
        let mut k_ptr = ptr::null();
        let mut k_len = 0usize;

        let val_ptr = unsafe {
            djson_object_next(self.ptr.as_ptr(), &mut k_ptr, &mut k_len)
        };

        if let Some(ptr) = ptr::NonNull::new(val_ptr) {
            let key_slice = unsafe { std::slice::from_raw_parts(k_ptr, k_len) };
            let key = std::str::from_utf8(key_slice).unwrap_or("");
            Some((
                key,
                DjsonValue {
                    ptr,
                    _marker: std::marker::PhantomData,
                },
            ))
        } else {
            None
        }
    }
}

impl<'a> Drop for DjsonObjectIter<'a> {
    fn drop(&mut self) {
        unsafe { djson_object_iter_free(self.ptr.as_ptr()) }
    }
}
