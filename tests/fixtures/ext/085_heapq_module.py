# heapq module

import heapq

# heappush and heappop
h = []
heapq.heappush(h, 3)
heapq.heappush(h, 1)
heapq.heappush(h, 4)
heapq.heappush(h, 1)
heapq.heappush(h, 5)
print(heapq.heappop(h))                           # 1
print(heapq.heappop(h))                           # 1
print(heapq.heappop(h))                           # 3

# heapify
data = [5, 3, 1, 4, 2]
heapq.heapify(data)
print(data[0])                                    # 1 (smallest at top)
print(sorted([heapq.heappop(data) for _ in range(len(data))]))  # [1, 2, 3, 4, 5]

# heappushpop
h2 = [1, 3, 5]
heapq.heapify(h2)
result = heapq.heappushpop(h2, 2)
print(result)                                     # 1
print(sorted(h2))                                 # [2, 3, 5]

# heapreplace
h3 = [1, 3, 5]
heapq.heapify(h3)
result2 = heapq.heapreplace(h3, 4)
print(result2)                                    # 1
print(sorted(h3))                                 # [3, 4, 5]

# nlargest and nsmallest
data2 = [3, 1, 4, 1, 5, 9, 2, 6, 5, 3]
print(heapq.nlargest(3, data2))                   # [9, 6, 5]
print(heapq.nsmallest(3, data2))                  # [1, 1, 2]

# nlargest/nsmallest with key
people = [('Alice', 30), ('Bob', 25), ('Charlie', 35)]
print(heapq.nlargest(2, people, key=lambda x: x[1]))  # [('Charlie', 35), ('Alice', 30)]

# merge (sorted iterables)
a = [1, 3, 5]
b = [2, 4, 6]
merged = list(heapq.merge(a, b))
print(merged)                                     # [1, 2, 3, 4, 5, 6]

# Heap sort
def heap_sort(lst):
    h = list(lst)
    heapq.heapify(h)
    return [heapq.heappop(h) for _ in range(len(h))]

print(heap_sort([5, 3, 1, 4, 2]))                # [1, 2, 3, 4, 5]

print('done')
