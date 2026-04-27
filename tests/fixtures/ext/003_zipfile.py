import zipfile
import io
import os
import tempfile

# ===== constants =====
print(zipfile.ZIP_STORED)                                # 0
print(zipfile.ZIP_DEFLATED)                              # 8

# ===== in-memory write / read (ZIP_STORED) =====
buf = io.BytesIO()
with zipfile.ZipFile(buf, 'w') as zf:
    zf.writestr('hello.txt', 'Hello, World!')
    zf.writestr('data/test.txt', 'nested file')

buf.seek(0)
with zipfile.ZipFile(buf, 'r') as zf:
    print(sorted(zf.namelist()))                         # ['data/test.txt', 'hello.txt']
    print(zf.read('hello.txt').decode())                 # Hello, World!
    print(zf.read('data/test.txt').decode())             # nested file

# ===== ZipInfo =====
buf.seek(0)
with zipfile.ZipFile(buf, 'r') as zf:
    info = zf.getinfo('hello.txt')
    print(info.filename)                                 # hello.txt
    print(isinstance(info.file_size, int))               # True
    print(info.file_size)                                # 13

# ===== is_zipfile =====
buf.seek(0)
print(zipfile.is_zipfile(buf))                           # True
print(zipfile.is_zipfile(io.BytesIO(b'not a zip')))      # False

# ===== infolist =====
buf.seek(0)
with zipfile.ZipFile(buf, 'r') as zf:
    infos = zf.infolist()
    print(len(infos))                                    # 2
    print(infos[0].filename)                             # hello.txt

# ===== open() =====
buf.seek(0)
with zipfile.ZipFile(buf, 'r') as zf:
    with zf.open('hello.txt') as f:
        print(f.read())                                  # b'Hello, World!'

# ===== ZIP_DEFLATED =====
buf2 = io.BytesIO()
data = b'aaaaaabbbbbbcccccc' * 100
with zipfile.ZipFile(buf2, 'w', compression=zipfile.ZIP_DEFLATED) as zf:
    zf.writestr('data.bin', data)
buf2.seek(0)
with zipfile.ZipFile(buf2, 'r') as zf:
    print(zf.read('data.bin') == data)                   # True

# ===== file-based operations =====
with tempfile.TemporaryDirectory() as td:
    zpath = os.path.join(td, 'test.zip')

    with zipfile.ZipFile(zpath, 'w') as zf:
        zf.writestr('file1.txt', 'content1')
        zf.writestr('file2.txt', 'content2')

    with zipfile.ZipFile(zpath, 'r') as zf:
        print(sorted(zf.namelist()))                     # ['file1.txt', 'file2.txt']
        print(zf.read('file1.txt'))                      # b'content1'
        print(zf.read('file2.txt'))                      # b'content2'

    # append mode
    with zipfile.ZipFile(zpath, 'a') as zf:
        zf.writestr('file3.txt', 'content3')

    with zipfile.ZipFile(zpath, 'r') as zf:
        print(sorted(zf.namelist()))                     # ['file1.txt', 'file2.txt', 'file3.txt']

print('done')
