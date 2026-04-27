# io module extended

import io

# StringIO
sio = io.StringIO()
sio.write('Hello, ')
sio.write('World!')
print(sio.getvalue())                              # Hello, World!

sio.seek(0)
print(sio.read())                                  # Hello, World!

sio.seek(7)
print(sio.read())                                  # World!

sio.seek(0)
print(sio.readline())                              # Hello, World!

# StringIO with initial value
sio2 = io.StringIO('initial content')
print(sio2.read())                                 # initial content
sio2.seek(0)
print(sio2.read(7))                                # initial

# BytesIO
bio = io.BytesIO()
bio.write(b'Hello')
bio.write(b' World')
print(bio.getvalue())                              # b'Hello World'

bio.seek(0)
print(bio.read(5))                                 # b'Hello'
print(bio.read())                                  # b' World'

# BytesIO with initial value
bio2 = io.BytesIO(b'initial')
print(bio2.read(4))                                # b'init'

# tell
bio3 = io.BytesIO(b'hello world')
bio3.read(5)
print(bio3.tell())                                 # 5

# truncate
sio3 = io.StringIO('hello world')
sio3.seek(5)
sio3.truncate()
sio3.seek(0)
print(sio3.read())                                 # hello

# StringIO readlines
sio4 = io.StringIO('line1\nline2\nline3\n')
lines = sio4.readlines()
print(lines)                                       # ['line1\n', 'line2\n', 'line3\n']

# write returns number of chars written
sio5 = io.StringIO()
n = sio5.write('hello')
print(n)                                           # 5

# BytesIO write returns number of bytes
bio4 = io.BytesIO()
n2 = bio4.write(b'world')
print(n2)                                          # 5

# getvalue after partial seek
sio6 = io.StringIO()
sio6.write('abc')
sio6.write('def')
sio6.seek(0)
print(sio6.getvalue())                             # abcdef

print('done')
