# contextlib extended

from contextlib import contextmanager, suppress, ExitStack

# contextmanager decorator
@contextmanager
def managed_resource(name):
    print(f'acquiring {name}')
    try:
        yield name
    finally:
        print(f'releasing {name}')

with managed_resource('db') as r:
    print(f'using {r}')
# acquiring db
# using db
# releasing db

# contextmanager with multiple yields prevented by cleanup
@contextmanager
def numbered(n):
    print(f'start {n}')
    yield n * 10
    print(f'end {n}')

with numbered(3) as val:
    print(f'got {val}')
# start 3
# got 30
# end 3

# Nested context managers
with managed_resource('a') as ra, managed_resource('b') as rb:
    print(f'{ra} and {rb}')
# acquiring a
# acquiring b
# a and b
# releasing b
# releasing a

# suppress
with suppress(ValueError):
    raise ValueError('ignored')
print('after suppress')                             # after suppress

with suppress(KeyError, TypeError):
    d = {}
    _ = d['missing']
print('after suppress 2')                           # after suppress 2

# suppress doesn't swallow non-matching
try:
    with suppress(ValueError):
        raise TypeError('not suppressed')
except TypeError as e:
    print(f'got: {e}')                             # got: not suppressed

# ExitStack
with ExitStack() as stack:
    r1 = stack.enter_context(managed_resource('r1'))
    r2 = stack.enter_context(managed_resource('r2'))
    print(f'using {r1} and {r2}')
# acquiring r1
# acquiring r2
# using r1 and r2
# releasing r2
# releasing r1

print('done')
