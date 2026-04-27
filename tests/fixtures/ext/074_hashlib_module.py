# hashlib module

import hashlib

# MD5
h = hashlib.md5(b'hello')
print(h.hexdigest())                               # 5d41402abc4b2a76b9719d911017c592

# SHA1
h2 = hashlib.sha1(b'hello')
print(h2.hexdigest())                              # aaf4c61ddcc5e8a2dabede0f3b482cd9aea9434d

# SHA256
h3 = hashlib.sha256(b'hello')
print(h3.hexdigest())                             # 2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824

# SHA512
h4 = hashlib.sha512(b'hello')
digest = h4.hexdigest()
print(len(digest))                                 # 128
print(digest[:8])                                  # 9b71d224

# Update
h5 = hashlib.md5()
h5.update(b'hel')
h5.update(b'lo')
print(h5.hexdigest())                              # 5d41402abc4b2a76b9719d911017c592

# digest_size
print(hashlib.md5().digest_size)                   # 16
print(hashlib.sha1().digest_size)                  # 20
print(hashlib.sha256().digest_size)                # 32

# digest (bytes)
d = hashlib.md5(b'hello').digest()
print(isinstance(d, bytes))                        # True
print(len(d))                                      # 16

# name
print(hashlib.md5().name)                          # md5
print(hashlib.sha256().name)                       # sha256

# copy
h6 = hashlib.sha256(b'hello')
h7 = h6.copy()
h7.update(b' world')
print(h6.hexdigest() == hashlib.sha256(b'hello').hexdigest())   # True
print(h7.hexdigest() == hashlib.sha256(b'hello world').hexdigest())  # True

# sha224
h8 = hashlib.sha224(b'test')
print(len(h8.hexdigest()))                         # 56

print('done')
