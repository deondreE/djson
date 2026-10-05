fn main() {
	println!("cargo:rustc-link-search=native=./djson_lib");
	println!("cargo:rustc-link-lib=static=djson");

	#[cfg(not(target_os = "windows"))]
	println!("cargo:rustc-link-lib=c");
}
