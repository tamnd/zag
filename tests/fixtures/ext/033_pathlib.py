import pathlib
import os
import tempfile

# Basic Path operations
p = pathlib.Path('/tmp/test/file.txt')
print(p.name)                                          # file.txt
print(p.suffix)                                        # .txt
print(p.stem)                                          # file
print(p.parent)                                        # /tmp/test

# Path joining
base = pathlib.Path('/home/user')
child = base / 'docs' / 'file.txt'
print(child.name)                                      # file.txt
print(str(child))                                      # /home/user/docs/file.txt

# Parts
parts = pathlib.Path('/a/b/c').parts
print(len(parts))                                      # 3
print(parts[0])                                        # /
print(parts[-1])                                       # c

# String conversion
p2 = pathlib.Path('/some/path')
print(str(p2))                                         # /some/path

# with_suffix / with_name
p3 = pathlib.Path('/dir/file.txt')
print(str(p3.with_suffix('.py')))                      # /dir/file.py
print(str(p3.with_name('other.txt')))                  # /dir/other.txt

# Absolute path on real filesystem
td = pathlib.Path(tempfile.gettempdir())
print(td.is_dir())                                     # True

# exists, is_file, is_dir
fake = pathlib.Path('/nonexistent/path')
print(fake.exists())                                   # False

# Pure paths
pp = pathlib.PurePath('/a/b/c.txt')
print(pp.suffix)                                       # .txt
print(pp.stem)                                         # c

print('done')
