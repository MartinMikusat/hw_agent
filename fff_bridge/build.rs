// Compiles fff-mcp's own cursor/output/server modules from the pinned checkout
// so hw_agent's tools behave exactly like fff-mcp: output.rs and cursor.rs are
// used in place; server.rs is copied with src/server_glue.rs appended (the glue
// needs the server's private tool methods); MCP_INSTRUCTIONS is lifted from
// main.rs, which cannot be compiled as a module.
use std::{env, fs, path::PathBuf};

fn main() {
    let manifest = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap());
    let src = manifest.join("../build/fff/src/crates/fff-mcp/src").canonicalize()
        .expect("fff checkout missing: run scripts/build_fff.sh");
    let out = PathBuf::from(env::var("OUT_DIR").unwrap());

    let main_rs = fs::read_to_string(src.join("main.rs")).unwrap();
    let start = main_rs.find("pub const MCP_INSTRUCTIONS: &str = concat!(").expect("MCP_INSTRUCTIONS not found");
    let end = start + main_rs[start..].find("\n);").expect("MCP_INSTRUCTIONS end not found") + 3;
    fs::write(out.join("instructions.rs"), &main_rs[start..end]).unwrap();

    let server = fs::read_to_string(src.join("server.rs")).unwrap();
    let glue = fs::read_to_string(manifest.join("src/server_glue.rs")).unwrap();
    fs::write(out.join("server.rs"), format!("{server}\n{glue}")).unwrap();

    let path = |p: PathBuf| p.to_str().unwrap().replace('\\', "/");
    fs::write(out.join("modules.rs"), format!(
        "#[path = \"{}\"] mod cursor;\n#[path = \"{}\"] mod output;\n#[allow(dead_code)] #[path = \"{}\"] mod server;\n",
        path(src.join("cursor.rs")), path(src.join("output.rs")), path(out.join("server.rs")),
    )).unwrap();

    for f in ["main.rs", "server.rs", "output.rs", "cursor.rs"] {
        println!("cargo:rerun-if-changed={}", src.join(f).display());
    }
    println!("cargo:rerun-if-changed=src/server_glue.rs");
}
