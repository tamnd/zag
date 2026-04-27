# json module

import json

# dumps basic types
print(json.dumps(42))                               # 42
print(json.dumps(3.14))                             # 3.14
print(json.dumps(True))                             # true
print(json.dumps(False))                            # false
print(json.dumps(None))                             # null
print(json.dumps('hello'))                          # "hello"

# dumps list and dict
print(json.dumps([1, 2, 3]))                        # [1, 2, 3]
print(json.dumps({'a': 1, 'b': 2}))                # {"a": 1, "b": 2}

# loads
print(json.loads('42'))                             # 42
print(json.loads('3.14'))                           # 3.14
print(json.loads('true'))                           # True
print(json.loads('false'))                          # False
print(json.loads('null'))                           # None
print(json.loads('"hello"'))                        # hello

data = json.loads('[1, 2, 3]')
print(data)                                         # [1, 2, 3]

obj = json.loads('{"name": "Alice", "age": 30}')
print(obj['name'])                                  # Alice
print(obj['age'])                                   # 30

# round-trip
original = {'users': [{'name': 'Alice', 'age': 30}, {'name': 'Bob', 'age': 25}]}
encoded = json.dumps(original)
decoded = json.loads(encoded)
print(decoded['users'][0]['name'])                  # Alice
print(decoded['users'][1]['age'])                   # 25

# indent
compact = json.dumps({'a': 1, 'b': [1, 2]}, indent=2)
print(compact)

# ensure_ascii
print(json.dumps({'key': 'value'}, ensure_ascii=True))   # {"key": "value"}

# sort_keys
d2 = {'b': 2, 'a': 1, 'c': 3}
print(json.dumps(d2, sort_keys=True))              # {"a": 1, "b": 2, "c": 3}

print('done')
