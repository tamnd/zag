import lzma
import os
import tempfile

# ===== compress / decompress =====
data = b"hello lzma world " * 50
compressed = lzma.compress(data)
print(isinstance(compressed, bytes))                      # True
print(compressed[:6] == b'\xfd7zXZ\x00')                 # True (XZ magic)
print(lzma.decompress(compressed) == data)               # True

# ===== preset levels =====
c1 = lzma.compress(data, preset=1)
c9 = lzma.compress(data, preset=9)
print(lzma.decompress(c1) == data)                       # True
print(lzma.decompress(c9) == data)                       # True

# ===== format constants =====
print(lzma.FORMAT_AUTO)                                  # 0
print(lzma.FORMAT_XZ)                                    # 1
print(lzma.FORMAT_ALONE)                                 # 2

# ===== bad data raises LZMAError =====
try:
    lzma.decompress(b"not valid lzma data!!")
except lzma.LZMAError:
    print("LZMAError raised")                            # LZMAError raised

# ===== multi-stream decompress =====
m1 = lzma.compress(b"stream1")
m2 = lzma.compress(b"stream2")
print(lzma.decompress(m1 + m2) == b"stream1stream2")    # True

# ===== LZMACompressor =====
c = lzma.LZMACompressor()
out = c.compress(b"hello ") + c.compress(b"lzma") + c.flush()
print(lzma.decompress(out) == b"hello lzma")             # True

c2 = lzma.LZMACompressor(preset=1)
out2 = c2.compress(b"level 1") + c2.flush()
print(lzma.decompress(out2) == b"level 1")               # True

# ===== LZMADecompressor basic =====
blob = lzma.compress(b"abcdefghij")
d = lzma.LZMADecompressor()
print(d.decompress(blob) == b"abcdefghij")               # True
print(d.eof)                                             # True
print(d.unused_data)                                     # b''

# ===== LZMADecompressor chunked =====
d2 = lzma.LZMADecompressor()
half = len(blob) // 2
p1 = d2.decompress(blob[:half])
p2 = d2.decompress(blob[half:])
print(p1 + p2 == b"abcdefghij")                         # True
print(d2.eof)                                            # True

# ===== LZMADecompressor unused_data =====
d3 = lzma.LZMADecompressor()
print(d3.decompress(blob + b"TRAILER") == b"abcdefghij") # True
print(d3.eof)                                            # True
print(d3.unused_data == b"TRAILER")                     # True

# ===== LZMADecompressor max_length =====
d4 = lzma.LZMADecompressor()
first = d4.decompress(blob, max_length=3)
print(first == b"abc")                                   # True
print(d4.needs_input)                                    # False
rest = d4.decompress(b"")
print(first + rest == b"abcdefghij")                     # True

with tempfile.TemporaryDirectory() as tmpdir:
    path = os.path.join(tmpdir, "test.xz")

    # ===== LZMAFile write =====
    with lzma.LZMAFile(path, 'w') as f:
        n = f.write(b"hello lzmafile")
        print(n)                                         # 14
        print(f.writable())                              # True
        print(f.readable())                              # False
        print(f.closed)                                  # False
    print(f.closed)                                      # True

    # ===== LZMAFile read =====
    with lzma.LZMAFile(path, 'r') as f:
        print(f.read())                                  # b'hello lzmafile'
        print(f.readable())                              # True
        print(f.writable())                              # False

    # ===== LZMAFile partial reads =====
    with lzma.LZMAFile(path, 'w') as f:
        f.write(b"abcdefghij")
    with lzma.LZMAFile(path, 'r') as f:
        print(f.read(3))                                 # b'abc'
        print(f.tell())                                  # 3
        print(f.read(3))                                 # b'def'
        print(f.read())                                  # b'ghij'

    # ===== LZMAFile readline =====
    lp = os.path.join(tmpdir, "lines.xz")
    with lzma.LZMAFile(lp, 'w') as f:
        f.write(b"line1\nline2\nline3")
    with lzma.LZMAFile(lp, 'r') as f:
        print(f.readline())                              # b'line1\n'
        print(f.readline())                              # b'line2\n'
        print(f.readline())                              # b'line3'
        print(f.readline())                              # b''

    # ===== LZMAFile peek =====
    with lzma.LZMAFile(path, 'r') as f:
        pk = f.peek(3)
        print(pk[:3])                                    # b'abc'
        print(f.tell())                                  # 0
        print(f.read(1))                                 # b'a'

    # ===== lzma.open binary =====
    p2 = os.path.join(tmpdir, "open.xz")
    with lzma.open(p2, 'wb') as f:
        f.write(b"lzma open write")
    with lzma.open(p2, 'rb') as f:
        print(f.read())                                  # b'lzma open write'

    # ===== lzma.open text =====
    p3 = os.path.join(tmpdir, "text.xz")
    with lzma.open(p3, 'wt') as f:
        f.write("hello text mode\n")
    with lzma.open(p3, 'rt') as f:
        print(f.read())                                  # hello text mode\n

    # ===== multiple writes =====
    p4 = os.path.join(tmpdir, "multi.xz")
    with lzma.LZMAFile(p4, 'w') as f:
        f.write(b"part1")
        f.write(b"part2")
        f.write(b"part3")
    with lzma.LZMAFile(p4, 'r') as f:
        print(f.read())                                  # b'part1part2part3'

print('done')
