import json

# Basic loads/dumps
data = {'name': 'Alice', 'age': 30, 'active': True, 'score': 9.5}
s = json.dumps(data, sort_keys=True)
print(type(s).__name__)                                # str

parsed = json.loads(s)
print(parsed['name'])                                  # Alice
print(parsed['age'])                                   # 30
print(parsed['active'])                                # True

# Lists
arr = [1, 2, 3, 'hello', None, True, False]
s2 = json.dumps(arr)
parsed2 = json.loads(s2)
print(parsed2)                                         # [1, 2, 3, 'hello', None, True, False]

# Nested
nested = {'a': {'b': {'c': 42}}}
s3 = json.dumps(nested)
parsed3 = json.loads(s3)
print(parsed3['a']['b']['c'])                          # 42

# dumps with indent
pretty = json.dumps({'x': 1}, indent=2)
print('\n' in pretty)                                  # True

# loads with list
arr2 = json.loads('[1, 2, 3]')
print(arr2)                                            # [1, 2, 3]

# null / bool
print(json.loads('null'))                              # None
print(json.loads('true'))                              # True
print(json.loads('false'))                             # False
print(json.loads('42'))                                # 42
print(json.loads('"hello"'))                           # hello

# dumps basic types
print(json.dumps(None))                                # null
print(json.dumps(True))                                # true
print(json.dumps(42))                                  # 42
print(json.dumps(3.14))                                # 3.14
print(json.dumps('hi'))                                # "hi"

# JSONDecodeError
try:
    json.loads('{invalid}')
except (json.JSONDecodeError, ValueError):
    print('decode error')                              # decode error

print('done')
