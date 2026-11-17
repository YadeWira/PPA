// zoprs IN ITERATIONS [raw]: the Rust port of zopfli (crate 0.8.3) as oxipng's
// --zopfli calls it (zopfli::compress, the input through a Box<dyn Read>);
// the zlib stream to stdout, or with "raw" the bare deflate (Format::Deflate)
use std::io::Write;
use std::num::NonZeroU64;

fn main() {
    let a: Vec<String> = std::env::args().collect();
    let data = std::fs::read(&a[1]).expect("IN");
    let it: u64 = a[2].parse().expect("ITERATIONS");
    let raw = a.get(3).map(|s| s == "raw").unwrap_or(false);
    let mut o = zopfli::Options::default();
    o.iteration_count = NonZeroU64::new(it).expect("ITERATIONS >= 1");
    let mut out = Vec::new();
    let format = if raw { zopfli::Format::Deflate } else { zopfli::Format::Zlib };
    zopfli::compress(o, format, Box::new(&data[..]) as Box<dyn std::io::Read>, &mut out).expect("compress");
    std::io::stdout().write_all(&out).expect("stdout");
}
