# collections.deque extended

from collections import deque

# Basic operations
d = deque([1, 2, 3])
print(list(d))                                      # [1, 2, 3]
print(len(d))                                       # 3

# appendleft and appendright
d.append(4)
d.appendleft(0)
print(list(d))                                      # [0, 1, 2, 3, 4]

# popleft and pop
print(d.popleft())                                  # 0
print(d.pop())                                      # 4
print(list(d))                                      # [1, 2, 3]

# extend and extendleft
d.extend([4, 5])
print(list(d))                                      # [1, 2, 3, 4, 5]
d.extendleft([0, -1])
print(list(d))                                      # [-1, 0, 1, 2, 3, 4, 5]

# rotate
d2 = deque([1, 2, 3, 4, 5])
d2.rotate(2)
print(list(d2))                                     # [4, 5, 1, 2, 3]
d2.rotate(-2)
print(list(d2))                                     # [1, 2, 3, 4, 5]

# maxlen
d3 = deque([1, 2, 3], maxlen=3)
d3.append(4)
print(list(d3))                                     # [2, 3, 4]
d3.appendleft(0)
print(list(d3))                                     # [0, 2, 3]
print(d3.maxlen)                                    # 3

# index, count, remove
d4 = deque([1, 2, 3, 2, 1])
print(d4.count(2))                                  # 2
print(d4.index(3))                                  # 2
d4.remove(2)
print(list(d4))                                     # [1, 3, 2, 1]

# insert
d5 = deque([1, 2, 3])
d5.insert(1, 10)
print(list(d5))                                     # [1, 10, 2, 3]

# reverse
d6 = deque([1, 2, 3, 4])
d6.reverse()
print(list(d6))                                     # [4, 3, 2, 1]

# copy
d7 = deque([1, 2, 3])
d8 = d7.copy()
d8.append(4)
print(list(d7))                                     # [1, 2, 3]
print(list(d8))                                     # [1, 2, 3, 4]

# Use as queue (FIFO)
queue = deque()
queue.append('first')
queue.append('second')
queue.append('third')
print(queue.popleft())                              # first
print(queue.popleft())                              # second

print('done')
