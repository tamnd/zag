from contextlib import contextmanager, suppress, nullcontext, closing, ExitStack

# contextmanager
@contextmanager
def managed(name):
    print('enter', name)                               # enter test
    yield name.upper()
    print('exit', name)                                # exit test

with managed('test') as val:
    print(val)                                         # TEST

# suppress
with suppress(ZeroDivisionError):
    x = 1 // 0
print('after suppress')                                # after suppress

# suppress does not hide other errors
try:
    with suppress(ValueError):
        raise TypeError('oops')
except TypeError:
    print('TypeError not suppressed')                  # TypeError not suppressed

# nullcontext
with nullcontext('hello') as v:
    print(v)                                           # hello

with nullcontext() as v:
    print(v is None)                                   # True

# closing
class Resource:
    def close(self):
        print('closed')                                # closed

with closing(Resource()):
    print('using resource')                            # using resource

# ExitStack
with ExitStack() as stack:
    stack.enter_context(managed('a'))                  # enter a
    stack.enter_context(managed('b'))                  # enter b
    print('inside stack')                              # inside stack
# exits in reverse: exit b then exit a

# ExitStack callback
log = []
with ExitStack() as stack:
    stack.callback(log.append, 'cb1')
    stack.callback(log.append, 'cb2')
print(log)                                             # ['cb2', 'cb1']

print('done')
