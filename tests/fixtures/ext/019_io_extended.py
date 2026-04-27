import io

# BytesIO
buf = io.BytesIO()
buf.write(b'hello world')
print(buf.tell())                                      # 11
buf.seek(0)
print(buf.read())                                      # b'hello world'

buf2 = io.BytesIO(b'abc')
print(buf2.read())                                     # b'abc'

# StringIO seek/tell
sbuf = io.StringIO()
sbuf.write('hello')
sbuf.write(' world')
sbuf.seek(0)
print(sbuf.read())                                     # hello world
print(sbuf.tell())                                     # 11

# readline
sbuf2 = io.StringIO('line1\nline2\nline3')
print(sbuf2.readline())                                # line1\n (printed as line1)
print(sbuf2.readline())                                # line2\n

# readlines
sbuf3 = io.StringIO('a\nb\nc\n')
lines = sbuf3.readlines()
print(len(lines))                                      # 3
print(lines[0].strip())                                # a

# truncate
sbuf4 = io.StringIO('hello world')
sbuf4.truncate(5)
sbuf4.seek(0)
print(sbuf4.read())                                    # hello

# getvalue
sbuf5 = io.StringIO()
sbuf5.write('test')
print(sbuf5.getvalue())                                # test

print('done')
