# pathlib basics

from pathlib import PurePosixPath

# PurePosixPath (no filesystem access, deterministic)
p = PurePosixPath('/home/user/docs/file.txt')
print(p.name)                                       # file.txt
print(p.stem)                                       # file
print(p.suffix)                                     # .txt
print(p.parent)                                     # /home/user/docs
print(p.parts)                                      # ('/', 'home', 'user', 'docs', 'file.txt')

# PurePath operations
p2 = PurePosixPath('/home/user') / 'docs' / 'file.py'
print(p2)                                           # /home/user/docs/file.py
print(p2.suffix)                                    # .py

# with_suffix
p3 = PurePosixPath('/home/user/file.txt')
p4 = p3.with_suffix('.py')
print(p4)                                           # /home/user/file.py

# with_name
p5 = p3.with_name('other.txt')
print(p5)                                           # /home/user/other.txt

# PurePosixPath joining
base = PurePosixPath('/etc')
config = base / 'nginx' / 'nginx.conf'
print(config)                                       # /etc/nginx/nginx.conf
print(config.parent.name)                           # nginx

# is_absolute
print(PurePosixPath('/home').is_absolute())        # True
print(PurePosixPath('home').is_absolute())         # False

# suffixes (multiple extensions)
p6 = PurePosixPath('/archive.tar.gz')
print(p6.suffixes)                                  # ['.tar', '.gz']
print(p6.stem)                                      # archive.tar

# relative_to
p7 = PurePosixPath('/home/user/docs/file.txt')
rel = p7.relative_to('/home/user')
print(rel)                                          # docs/file.txt

print('done')
