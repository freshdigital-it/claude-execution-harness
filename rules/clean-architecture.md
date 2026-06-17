---
alwaysApply: true
---

# Clean Architecture & Code Quality Rules
# Applies to ALL projects, ALL languages, ALL sessions.

## CRITICAL: These rules are NON-NEGOTIABLE

Every file you write or edit must follow these rules.
If a rule conflicts with a user request, flag it explicitly before proceeding.
Rules with **[HARD]** tag = never violate. Rules with **[SOFT]** = flag if violating.

---

## Universal Rules (Every Language)

### File Size **[HARD]**
- Maximum **300 lines** per file for new code
- Maximum **500 lines** for editing existing files (never make them longer)
- If a file you are editing already exceeds 500 lines, offer to split it
- Config files, generated files, and migrations are exempt
- **Violation response**: "This file would exceed the 300-line limit. I'll split it into [X] and [Y]."

### Method / Function Length **[HARD]**
- Maximum **30 lines** per method or function (excluding blank lines and comments)
- A method that does more than one thing must be split
- **Extraction pattern**: extract to private helper methods named by what they do

### Single Responsibility **[HARD]**
- One class = one reason to change
- One function = one action with one outcome
- If you need the word "and" to describe what a class does, it needs splitting
- **Test**: can you name this class/function in 3 words without "and"?

### Cyclomatic Complexity **[SOFT]**
- Max **10** branches per method (each if/else/case/catch/while/for/&& adds 1)
- If complexity would exceed 10, extract into smaller methods or use strategy pattern
- **Flag message**: "This method has CC={N}. I'll refactor using [pattern]."

### Constructor Dependencies **[SOFT]**
- Maximum **5** injected dependencies per constructor
- If a class needs more than 5, it's doing too much — split the class
- Group related dependencies into a Value Object or Service Aggregate

### Public Interface Size **[SOFT]**
- Maximum **7 public methods** per class
- Getters/setters don't count toward the limit
- Each public method is a contract — minimize what you expose

---

## PHP / Laravel Rules

### Controllers **[HARD]**
- Every controller must be **invokable single-action** (`__invoke` only)
- No controller may have more than 1 public method
- Route → Controller → Service. Controllers do NOT contain business logic.
```php
// CORRECT
class CreateInvoiceController
{
    public function __invoke(CreateInvoiceRequest $request, InvoiceWorkflowService $service): JsonResponse
    {
        return response()->json($service->createDraft($request->validated()));
    }
}
// WRONG: InvoiceController with create(), store(), show(), update(), destroy()
```

### Services **[HARD]**
- Service classes: max 5 public methods, each under 30 lines
- If a service grows beyond this, extract an Action class per operation
- Never call one service from another service directly — use Events

### Domain Boundaries **[HARD]**
- `app/Domain/CRM/` must never import from `app/Domain/Finance/`
- Cross-domain communication via Events and Listeners only
- Shared value objects go in `app/Domain/Shared/`

### Laravel Patterns (prefer always) **[SOFT]**
- Use Form Requests for all validation — never validate in controllers
- Use Policies for all authorization — never check `auth()->user()->role` inline
- Use Jobs/Queues for anything that takes > 100ms
- Use `readonly` classes for DTOs (PHP 8.2+)

### Type Safety **[HARD]**
- All method signatures must have full return types and parameter types
- No `mixed` type unless wrapping an external library boundary
- No `array` without a docblock shape: `/** @param array{id: int, name: string} $data */`

---

## Vue / TypeScript Rules

### Component Structure **[HARD]**
- Template block: max **100 lines**
- Script setup block: max **150 lines**
- Style block: max **50 lines**
- Total component: max **300 lines**
- If a component exceeds this, extract into child components

### Component Responsibility **[HARD]**
- A Vue component handles ONE visual concern
- No business logic in components — extract to composables
- No API calls in components — use composables or stores
```typescript
// CORRECT: component delegates to composable
const { invoices, isLoading, createInvoice } = useInvoices()

// WRONG: fetch inside component
const invoices = ref([])
onMounted(async () => { invoices.value = await axios.get('/api/invoices') })
```

### TypeScript **[HARD]**
- No `any` type — use `unknown` and narrow, or define the interface
- All exported functions must have explicit return types
- All props must be typed with `defineProps<{ ... }>()`
- No implicit `undefined` — use optional chaining and nullish coalescing

### Composables **[SOFT]**
- Every composable under 80 lines
- Returns object (not array) for named destructuring
- Composable name: `use` + noun (`useInvoice`, `useAuthUser`)

---

## Python Rules

### File size **[HARD]**
- Max 300 lines per module
- One class per file for domain objects
- `__init__.py` must only re-export, no logic

### Functions **[HARD]**
- Max 30 lines per function
- No mutable default arguments
- Always type-annotate function signatures (Python 3.10+)

### Classes **[SOFT]**
- Prefer dataclasses or Pydantic models for data containers
- Max 7 public methods
- No inheritance deeper than 2 levels

---

## Go Rules

### File size **[HARD]**
- Max 300 lines per file
- One exported type per file (unless trivially small)

### Functions **[HARD]**
- Max 30 lines
- Return `(T, error)` — never panic in library code
- Error messages: lowercase, no punctuation, wrap with `fmt.Errorf("...: %w", err)`

---

## Security Rules (All Languages) **[HARD]**

- NEVER hardcode secrets, API keys, passwords, tokens in source code
- NEVER commit `.env` files
- ALWAYS validate input at system boundaries (HTTP handlers, CLI args, event consumers)
- ALWAYS sanitize file paths: `path.Clean()`, `filepath.Abs()`, `realpath()`
- SQL: parameterized queries only — never string concatenation
- Auth checks must happen in middleware/policy, not inside business logic

---

## Testing Rules **[SOFT]**

- Every new public method must have at least one test
- Prefer TDD London School (mock collaborators, test behavior not implementation)
- Test file lives next to source file or in `/tests` mirroring the source tree
- Test names: `test_[method]_[scenario]_[expected_outcome]`
- No test may have more than 3 assertions (one behavior per test)

---

## Git / PR Rules **[SOFT]**

- Branch naming: `(feature|fix|release|hotfix|docs|chore)/[a-z0-9]+(-[a-z0-9]+)*`
- Commit messages: imperative mood, under 72 chars, explain WHY not WHAT
- PRs must not mix refactoring with feature work — separate commits/PRs
- Every PR touching business logic needs a test

---

## When You Encounter a Large File

If asked to edit a file over 300 lines, you MUST:
1. State the current line count
2. Identify the splitting boundary (separate concerns)
3. Propose split names before writing code
4. Ask for confirmation if the split changes public interfaces

Example response:
> "This file is 847 lines. I'll split it:
> - `InvoiceQueryService.php` (line fetching, 150 lines)
> - `InvoiceWorkflowService.php` (state transitions, 200 lines)
> - `InvoiceGlPostingService.php` (GL integration, 120 lines)
> Proceed with this split?"

---

## Enforcement Reference (when in a repo with tooling)

If the project has these files, run them before declaring work complete:
```bash
bash scripts/check_file_sizes.sh          # File size gate
composer phpmd                             # PHP complexity
composer phpstan                           # PHP type safety
npm run check:sizes                        # Vue/TS file audit
npm run type-check                         # TypeScript strict
```
