use backhand::compression::Compressor;
use backhand::{FilesystemCompressor, FilesystemWriter, NodeHeader};
use extism_pdk::*;
use serde::Deserialize;
use std::fs;
use std::fs::File;
use std::io::Cursor;
use std::path::Path;

#[derive(Deserialize)]
struct FileEntry {
    path: String,
    mode: u16,
    is_dir: bool,
}

#[derive(Deserialize)]
struct PackRequest {
    entries: Vec<FileEntry>,
    src_root: String,
    out_path: String,
}

#[plugin_fn]
pub fn pack(Json(req): Json<PackRequest>) -> FnResult<String> {
    let mut fsw = FilesystemWriter::default();
    fsw.set_compressor(FilesystemCompressor::new(Compressor::Gzip, None)?);
    fsw.set_root_mode(0o755);

    for entry in &req.entries {
        if entry.is_dir {
            fsw.push_dir_all(&entry.path, NodeHeader::new(entry.mode, 0, 0, 0))?;
        } else {
            let full = Path::new(&req.src_root).join(&entry.path);
            let data = fs::read(&full)?;
            fsw.push_file(
                Cursor::new(data),
                &entry.path,
                NodeHeader::new(entry.mode, 0, 0, 0),
            )?;
        }
    }

    let mut out = File::create(&req.out_path)?;
    fsw.write(&mut out)?;

    Ok(format!("packed {} entries ok", req.entries.len()))
}
