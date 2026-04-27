import os
import os.path

# join
p = os.path.join('/home', 'user', 'file.txt')
print(p)                                              # /home/user/file.txt

p2 = os.path.join('a', 'b', 'c')
print(p2)                                             # a/b/c

# split
head, tail = os.path.split('/home/user/file.txt')
print(head)                                           # /home/user
print(tail)                                           # file.txt

# splitext
root, ext = os.path.splitext('file.txt')
print(root)                                           # file
print(ext)                                            # .txt

# basename, dirname
print(os.path.basename('/home/user/file.txt'))        # file.txt
print(os.path.dirname('/home/user/file.txt'))         # /home/user

# exists (on real path)
print(os.path.exists('/tmp'))                         # True
print(os.path.exists('/nonexistent_path_xyz'))        # False

# isabs
print(os.path.isabs('/home/user'))                    # True
print(os.path.isabs('relative/path'))                 # False

# normpath
print(os.path.normpath('/home/./user/../user/file'))  # /home/user/file

# expanduser
home = os.path.expanduser('~')
print(isinstance(home, str))                          # True
print(len(home) > 0)                                  # True

print('done')
