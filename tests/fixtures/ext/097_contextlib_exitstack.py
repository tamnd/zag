# contextlib.ExitStack and more

from contextlib import ExitStack, contextmanager, suppress

# ExitStack basic usage
with ExitStack() as stack:
    stack.callback(print, 'callback 1')
    stack.callback(print, 'callback 2')
    print('inside stack')
# inside stack
# callback 2
# callback 1

# ExitStack with context managers
@contextmanager
def managed(name):
    print(f'enter {name}')
    yield name
    print(f'exit {name}')

with ExitStack() as stack:
    r1 = stack.enter_context(managed('A'))
    r2 = stack.enter_context(managed('B'))
    print(f'using {r1} and {r2}')
# enter A
# enter B
# using A and B
# exit B
# exit A

# suppress context manager
with suppress(ValueError):
    raise ValueError('suppressed')
print('after suppress')                            # after suppress

with suppress(KeyError, IndexError):
    d = {}
    _ = d['missing']
print('after suppress 2')                         # after suppress 2

# suppress does NOT suppress unmatched exceptions
try:
    with suppress(ValueError):
        raise TypeError('not suppressed')
except TypeError:
    print('TypeError not suppressed')             # TypeError not suppressed

# ExitStack cleanup on exception
results = []
try:
    with ExitStack() as stack:
        stack.callback(results.append, 'cleanup1')
        stack.callback(results.append, 'cleanup2')
        raise RuntimeError('test error')
except RuntimeError:
    pass
print(results)                                     # ['cleanup2', 'cleanup1']

print('done')
