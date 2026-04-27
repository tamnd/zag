# List methods and operations

# Basic operations
lst = [3, 1, 4, 1, 5, 9, 2, 6]
print(len(lst))                                       # 8
print(lst[0])                                         # 3
print(lst[-1])                                        # 6
print(lst[2:5])                                       # [4, 1, 5]

# append, extend, insert
lst2 = [1, 2, 3]
lst2.append(4)
print(lst2)                                           # [1, 2, 3, 4]
lst2.extend([5, 6])
print(lst2)                                           # [1, 2, 3, 4, 5, 6]
lst2.insert(2, 99)
print(lst2)                                           # [1, 2, 99, 3, 4, 5, 6]

# remove, pop, clear
lst2.remove(99)
print(lst2)                                           # [1, 2, 3, 4, 5, 6]
popped = lst2.pop()
print(popped)                                         # 6
popped2 = lst2.pop(0)
print(popped2)                                        # 1
print(lst2)                                           # [2, 3, 4, 5]

# index, count
lst3 = [1, 2, 3, 2, 1]
print(lst3.index(2))                                  # 1
print(lst3.count(1))                                  # 2
print(lst3.count(2))                                  # 2

# sort, reverse
lst4 = [3, 1, 4, 1, 5, 9]
lst4.sort()
print(lst4)                                           # [1, 1, 3, 4, 5, 9]
lst4.sort(reverse=True)
print(lst4)                                           # [9, 5, 4, 3, 1, 1]

lst5 = ['banana', 'apple', 'cherry']
lst5.sort(key=len)
print(lst5)                                           # ['apple', 'banana', 'cherry']

lst6 = [1, 2, 3]
lst6.reverse()
print(lst6)                                           # [3, 2, 1]

# copy
lst7 = [1, 2, 3]
lst8 = lst7.copy()
lst8.append(4)
print(lst7)                                           # [1, 2, 3]
print(lst8)                                           # [1, 2, 3, 4]

# Concatenation, repetition
a = [1, 2] + [3, 4]
print(a)                                              # [1, 2, 3, 4]
b = [0] * 4
print(b)                                              # [0, 0, 0, 0]

# List as stack
stack = []
stack.append(1)
stack.append(2)
stack.append(3)
print(stack.pop())                                    # 3
print(stack.pop())                                    # 2

# Nested list
matrix = [[1, 2], [3, 4], [5, 6]]
print(matrix[1][0])                                   # 3
flat = sum(matrix, [])
print(flat)                                           # [1, 2, 3, 4, 5, 6]

print('done')
