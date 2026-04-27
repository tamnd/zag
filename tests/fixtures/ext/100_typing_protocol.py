# typing.Protocol structural subtyping

from typing import Protocol

# Basic Protocol
class Drawable(Protocol):
    def draw(self) -> str: ...

class Circle:
    def draw(self) -> str:
        return 'drawing circle'

class Square:
    def draw(self) -> str:
        return 'drawing square'

def render(shape: Drawable) -> str:
    return shape.draw()

print(render(Circle()))                            # drawing circle
print(render(Square()))                            # drawing square

# Protocol with multiple methods
class Container(Protocol):
    def __contains__(self, item) -> bool: ...
    def __len__(self) -> int: ...

# Structural subtyping (duck typing) - actual use without isinstance
class Stack:
    def __init__(self):
        self._items = []
    def push(self, item):
        self._items.append(item)
    def pop(self):
        return self._items.pop()
    def __len__(self):
        return len(self._items)
    def __contains__(self, item):
        return item in self._items

s = Stack()
s.push(1)
s.push(2)
s.push(3)
print(len(s))                                      # 3
print(1 in s)                                      # True
print(4 in s)                                      # False

popped = s.pop()
print(popped)                                      # 3
print(len(s))                                      # 2

# Protocol with default method
class Comparable(Protocol):
    def __lt__(self, other) -> bool: ...

def find_min(items):
    result = items[0]
    for item in items[1:]:
        if item < result:
            result = item
    return result

print(find_min([3, 1, 4, 1, 5, 9, 2]))           # 1
print(find_min(['banana', 'apple', 'cherry']))    # apple

# Callable protocol
class Transformer(Protocol):
    def __call__(self, x: int) -> int: ...

def apply(f: Transformer, values):
    return [f(x) for x in values]

print(apply(lambda x: x * 2, [1, 2, 3]))         # [2, 4, 6]
print(apply(lambda x: x ** 2, [1, 2, 3, 4]))     # [1, 4, 9, 16]

print('done')
