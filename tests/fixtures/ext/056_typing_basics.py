# typing module basics

from typing import Optional, Union, List, Dict, Tuple, Set, Any, Callable

# Type annotations are just metadata, no runtime enforcement
def greet(name: str) -> str:
    return f'Hello, {name}'

print(greet('Alice'))                                # Hello, Alice

# Optional
def find(lst: List[int], val: int) -> Optional[int]:
    for i, x in enumerate(lst):
        if x == val:
            return i
    return None

print(find([1, 2, 3], 2))                           # 1
print(find([1, 2, 3], 5))                           # None

# Union
def double(x: Union[int, float]) -> Union[int, float]:
    return x * 2

print(double(5))                                     # 10
print(double(3.14))                                  # 6.28

# List, Dict type hints (just annotations)
def sum_list(lst: List[int]) -> int:
    return sum(lst)

print(sum_list([1, 2, 3, 4, 5]))                    # 15

def merge_dicts(a: Dict[str, int], b: Dict[str, int]) -> Dict[str, int]:
    result = dict(a)
    result.update(b)
    return result

d = merge_dicts({'a': 1}, {'b': 2})
print(sorted(d.items()))                             # [('a', 1), ('b', 2)]

# Callable
def apply(fn: Callable[[int], int], x: int) -> int:
    return fn(x)

print(apply(lambda x: x * 3, 7))                    # 21

# Any accepts anything
def identity(x: Any) -> Any:
    return x

print(identity(42))                                  # 42
print(identity('hello'))                             # hello

# Tuple annotation
def swap(t: Tuple[int, str]) -> Tuple[str, int]:
    return (t[1], t[0])

a, b = swap((1, 'one'))
print(a)                                             # one
print(b)                                             # 1

print('done')
