import hashlib

# sha256
h = hashlib.sha256()
h.update(b'hello')
h.update(b' world')
digest = h.hexdigest()
print(len(digest))                                     # 64
print(digest == hashlib.sha256(b'hello world').hexdigest())  # True

# md5
m = hashlib.md5(b'test')
print(len(m.hexdigest()))                              # 32
print(m.digest_size)                                   # 16

# sha1
s1 = hashlib.sha1(b'abc')
print(len(s1.hexdigest()))                             # 40

# sha512
s5 = hashlib.sha512(b'abc')
print(len(s5.hexdigest()))                             # 128
print(s5.digest_size)                                  # 64

# copy
h2 = hashlib.sha256(b'hello')
h3 = h2.copy()
h2.update(b' world')
h3.update(b' there')
print(h2.hexdigest() != h3.hexdigest())                # True

# new()
h4 = hashlib.new('sha256', b'abc')
print(len(h4.hexdigest()))                             # 64

# algorithms_available
algos = hashlib.algorithms_available
print('sha256' in algos)                               # True
print('md5' in algos)                                  # True

# block_size
print(hashlib.sha256().block_size)                     # 64

print('done')
