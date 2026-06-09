# Knative-O — Instrukcja przeprowadzenia demo

Dokument opisuje krok po kroku jak odpalić demo, co pokazywać i jakie komendy wydawać.
Zajmuje ok. **40–50 minut** (wliczając bootstrap ~25 min).

---

## 0. Przed demo — jednorazowa instalacja

### 0.1 Wymagania

```bash
# Sprawdź, że masz:
docker --version        # 24+
kind version            # 0.23+
kubectl version --client
helm version
```

### 0.2 Konfiguracja .env

```bash
cp .env.example .env
```

Uzupełnij w `.env`:
```
OPENAI_API_KEY=sk-...   # lub ANTHROPIC_API_KEY
LLM_MODEL=gpt-4o        # lub claude-sonnet-4-6
GRAFANA_ADMIN_PASSWORD=demo123
WEBHOOK_TOKEN=demo-token-secret
AGENT_MODE=confirm       # na demo zmienisz ręcznie, lub confirm przez cały czas
```

### 0.3 Bootstrap (~25 min, jednorazowo)

```bash
make bootstrap
```

Bootstrap przechodzi przez 8 faz:
1. Tworzy klaster kind `knative-o`
2. Instaluje cert-manager
3. Instaluje Knative Operator + KnativeServing + KnativeEventing
4. Weryfikuje Kourier (ingress)
5. Instaluje Prometheus + Grafana + OTel Operator + OTel Collector + Zipkin
6. Buduje i ładuje obraz agenta LangChain do klastra
7. Instaluje Astronomy Shop (Helm)
8. Smoke test (4 testy: frontend, endpointy, Prometheus, agent)

**Po zakończeniu powinieneś zobaczyć:**
```
✓ Astronomy Shop deployed
✓ Smoke test: all checks passed
Knative-O is up.
```

### 0.4 Przygotuj okna terminala i przeglądarkę

Otwórz **4 okna/panele terminala** i **2 zakładki przeglądarki**:

| Terminal | Co tam trzymasz |
|----------|-----------------|
| T1 | Komendy demo (wpisujesz tu scenariusze) |
| T2 | `kubectl get pods -n astronomy-shop -w` (watch na pody) |
| T3 | `kubectl logs -n mcp deploy/langchain-agent -f` (logi agenta) |
| T4 | `make grafana` (zostaw uruchomione przez całe demo) |

```bash
# T2
kubectl get pods -n astronomy-shop -w

# T3
kubectl logs -n mcp deploy/langchain-agent -f

# T4
make grafana
# → http://localhost:3000  (admin / twoje GRAFANA_ADMIN_PASSWORD)
```

W przeglądarce otwórz:
- **Tab 1:** http://localhost:3000 → Dashboards → `Knative-O — Revisions`
- **Tab 2:** http://localhost:8081 (odpalić po `make shop` w osobnym terminalu)

---

## 1. Wstęp — pokaż działający Astronomy Shop

```bash
# W osobnym terminalu (lub T1):
make shop
# → http://localhost:8081
```

**Co pokazujesz:**
1. Otwórz http://localhost:8081 — skep astronomiczny działa, ładuje produkty, koszyk itp.
2. Pokaż, że `currency` to zwykły Kubernetes Deployment:

```bash
kubectl get deploy -n astronomy-shop currency
kubectl get svc -n astronomy-shop currency
```

**Co mówisz:**
> "To jest OpenTelemetry Astronomy Shop — aplikacja demonstracyjna z wieloma mikroserwisami.
> Serwis `currency` przelicza waluty i jest teraz zwykłym Deploymentem.
> Za chwilę poprosimy agenta LLM, żeby wystawił go jako Knative Service."

---

## Scenariusz 1 — Cold start (wdrożenie przez agenta)

**Co demonstruje:** Agent LLM (LangChain + GPT-4o/Claude) czyta istniejący Deployment,
konstruuje manifest Knative Service i aplikuje go przez MCP tools na klaster.

### Komendy

```bash
# T1
make scenario-1
```

### Co oglądasz w trakcie (ok. 2–3 min)

**T3 (logi agenta)** — zobaczysz tok rozumowania LLM:
```
> Entering new AgentExecutor chain...
Using tool: resources_get  (czyta Deployment/currency)
Using tool: resources_create_or_update  (tworzy ksvc/currency-knative)
```

**T2 (watch pods)** — pojawi się nowy pod z prefixem `currency-knative-`:
```
currency-knative-00001-deployment-xxxxx   0/3   ContainerCreating   ...
currency-knative-00001-deployment-xxxxx   3/3   Running             ...
```

**T4 (Grafana)** — w dashboardzie `Knative-O — Revisions` zobaczysz:
- "Total active pods" skoczy z 0 do 1
- Pojawi się linia `currency-knative-00001` na wykresie "Pods per revision"

### Po zakończeniu pokaż

```bash
# Pokaż że ksvc istnieje i ma URL
kubectl get ksvc -n astronomy-shop currency-knative

# Pokaż pełny manifest który stworzył agent
kubectl get ksvc -n astronomy-shop currency-knative -o yaml
```

**Co mówisz:**
> "Agent w jednym kroku odczytał konfigurację istniejącego serwisu i
> stworzył Knative Service z identycznym obrazem i zmiennymi środowiskowymi.
> Zwróćcie uwagę na adnotacje autoscalera: min-scale=0, max-scale=5.
> Oznacza to, że serwis może skalować się do zera."

---

## Scenariusz 4 — Scale-to-zero i cold start

**Co demonstruje:** Pod znika gdy nie ma ruchu; pierwsze zapytanie budzi go (cold start).

> **Uwaga:** Ten scenariusz odpalaj **po scenariuszu 1**, ale **przed** generowaniem ruchu.
> Poczekaj kilka minut od sc.1 żeby pod zdążył się zerowywać (domyślnie ~90s bez ruchu).

### Komendy

```bash
# T1
make scenario-4
```

Skrypt:
1. Czeka, aż liczba podów spadnie do 0 (potwierdza scale-to-zero)
2. Wysyła jedno żądanie HTTP na URL serwisu
3. Mierzy czas od żądania do odpowiedzi (cold start latency)

### Co oglądasz

**T2 (watch pods)** — pod znika po ~90s bezczynności:
```
currency-knative-00001-deployment-xxxxx   Terminating
# (po chwili — brak podów z tym prefixem)
```

Następnie po wysłaniu żądania:
```
currency-knative-00001-deployment-xxxxx   0/3   Pending
currency-knative-00001-deployment-xxxxx   0/3   ContainerCreating
currency-knative-00001-deployment-xxxxx   3/3   Running
```

**T4 (Grafana)** — wykres "Pods per revision" skoczy 0 → 1.

**Co mówisz:**
> "Knative automatycznie zerowuje pody gdy nie ma ruchu.
> Pierwsze żądanie trafia do `activatora`, który budzi pod i przekierowuje ruch.
> Cold start trwa tu kilka sekund — w produkcji można go minimalizować przez min-scale=1."

---

## Scenariusz 2 — Canary (podział ruchu 90/10)

**Co demonstruje:** Agent tworzy nową rewizję i ustawia ruch 90% stara / 10% nowa.

### Komendy

```bash
# T1
make scenario-2
```

### Co oglądasz (ok. 1–2 min)

**T3 (logi agenta)** — agent:
1. Pobiera pełny spec ksvc (`resources_get`)
2. Dodaje adnotację `canary.knative-o.dev/revision: v2` (wymusza nową rewizję)
3. Ustawia `spec.traffic` na dwa wpisy: 90% stara, 10% nowa
4. Aplikuje przez `resources_create_or_update`

### Po zakończeniu pokaż

```bash
# Pokaż podział ruchu
kubectl get ksvc -n astronomy-shop currency-knative \
  -o jsonpath='{.status.traffic}' | python3 -m json.tool
```

Wynik powinien wyglądać tak:
```json
[
  {"revisionName": "currency-knative-00001", "percent": 90},
  {"revisionName": "currency-knative-00002", "percent": 10}
]
```

```bash
# Wygeneruj trochę ruchu żeby Grafana miała dane
make traffic   # 5 req/s przez 2 min
```

**T4 (Grafana)** — "Pods per revision" pokaże dwie linie z różnym natężeniem.

**Co mówisz:**
> "Canary release bez żadnego YAML-a ręcznie pisanego.
> Agent zrozumiał intencję, pobrał aktualny stan i zmodyfikował tylko `spec.traffic`.
> 90% ruchu nadal idzie na starą rewizję, 10% testuje nową."

---

## Scenariusz 3 — Tuning autoscalera

**Co demonstruje:** Agent zmienia parametry skalowania (target concurrency, max-scale).

### Komendy

```bash
# T1
make scenario-3
```

Agent zmienia:
- `autoscaling.knative.dev/target`: `100` → `50` (skaluje szybciej)
- `autoscaling.knative.dev/max-scale`: `5` → `20` (więcej podów max)

### Po zakończeniu pokaż

```bash
kubectl get ksvc -n astronomy-shop currency-knative \
  -o jsonpath='{.spec.template.metadata.annotations}' | python3 -m json.tool
```

Następnie wyślij ruch i obserwuj skalowanie:

```bash
make traffic   # 5 req/s, 2 min
```

**T4 (Grafana)** — panel "Concurrency: stable vs target" pokaże skok; autoscaler doda pody gdy `stable > target`.

**Co mówisz:**
> "Agent zmienił próg skalowania — teraz przy 50 jednoczesnych połączeniach
> Knative doda nowy pod. Przy obciążeniu widać na Grafanie, jak autoscaler
> reaguje w czasie rzeczywistym."

---

## Scenariusz 5 — Diagnoza awarii przez agenta

**Co demonstruje:** Agent diagnostycznie czyta stan klastra i identyfikuje przyczynę awarii.

### Komendy

```bash
# T1
make scenario-5
```

Skrypt:
1. Wstrzykuje błędny tag obrazu (symuluje bug w CI/CD)
2. Czeka ~30s aż rewizja wchodzi w `ImagePullBackOff`
3. Pyta agenta: "dlaczego `currency-knative` nie jest Ready?"
4. Przywraca poprawny obraz

### Co oglądasz (ok. 2 min)

**T2 (watch pods)** — pojawi się pod w stanie `ImagePullBackOff`:
```
currency-knative-00003-deployment-xxxxx   0/3   ImagePullBackOff
```

**T3 (logi agenta)** — agent sekwencyjnie:
```
Using tool: resources_get  (czyta ksvc)
→ status.conditions: Ready=False, reason="RevisionFailed"

Using tool: resources_get  (czyta rewizję)
→ status.conditions: ContainerHealthy=False, reason="ImagePullBackOff"

Using tool: resources_get  (czyta pod)
→ events: "Failed to pull image: not found"
```

### Po zakończeniu pokaż output agenta

```bash
kubectl logs -n mcp deploy/langchain-agent --tail=80
```

**Co mówisz:**
> "Agent przeszedł przez hierarchię obiektów: Service → Revision → Pod → Events
> i wskazał dokładną przyczynę. To tylko operacje read-only — agent nie modyfikował nic.
> Takie samo narzędzie może działać w nocy, gdy nie ma nikogo on-call."

---

## Scenariusz 6 — Rollback

**Co demonstruje:** Agent cofa ruch do poprzedniej rewizji.

> Wymaga ukończenia scenariusza 2 (min. 2 rewizje).

### Komendy

```bash
# T1
make scenario-6
```

Agent:
1. Pobiera listę rewizji
2. Identyfikuje poprzednią stabilną
3. Ustawia `spec.traffic: [{revisionName: <stara>, percent: 100}]`

### Po zakończeniu pokaż

```bash
kubectl get ksvc -n astronomy-shop currency-knative \
  -o jsonpath='{.status.traffic}' | python3 -m json.tool
```

**Co mówisz:**
> "Rollback zajął agentowi dosłownie kilka sekund.
> W tradycyjnym flow: ktoś musi znaleźć poprzedni tag, zaktualizować Helm values,
> zrobić kubectl apply. Tutaj — jedna komenda, agent robi resztę."

---

## Scenariusz 7 — Reaktywne skalowanie (closed loop)

**Co demonstruje:** Alert z Alertmanagera trafia do agenta, który autonomicznie zmienia konfigurację.

> **Najważniejszy scenariusz** — pokazuje pętlę: Obserwability → Alert → Agent → Zmiana.

### Przygotowanie

Skrypt automatycznie przełącza agenta w tryb `auto` jeśli jest w `confirm`.

### Komendy

```bash
# T1
make scenario-7
```

Skrypt:
1. Port-forwarduje agenta na `localhost:18080`
2. Wysyła syntetyczny payload Alertmanagera (alert `HighRequestLatency`)
3. Czeka aż agent zmieni `max-scale` i `target` w ksvc

### Co oglądasz (ok. 1.5 min)

**T3 (logi agenta)** — widać jak agent:
```
Received alert: HighRequestLatency on currency-knative
→ p95 latency 1.4s, above 1s SLO
Using tool: resources_get (czyta ksvc)
Using tool: resources_create_or_update (zwiększa max-scale, obniża target)
```

### Po zakończeniu pokaż

```bash
kubectl get ksvc -n astronomy-shop currency-knative \
  -o jsonpath='{.spec.template.metadata.annotations}' | python3 -m json.tool
```

**Co mówisz:**
> "To jest zamknięta pętla: Prometheus wykrywa wysokie opóźnienie,
> Alertmanager wysyła webhook do agenta, agent analizuje kontekst przez LLM
> i autonomicznie zmienia konfigurację Knative — bez człowieka w pętli.
> W realnym wdrożeniu AGENT_MODE=confirm wymaga zatwierdzenia; tu używamy auto
> żeby pokazać pełną automatyzację."

---

## Po demo — przydatne komendy

```bash
# Pokaż wszystkie rewizje
kubectl get revisions -n astronomy-shop

# Pokaż Prometheus targets (sprawdź czy 4x UP)
kubectl get --raw '/api/v1/namespaces/monitoring/services/prometheus-operated:9090/proxy/api/v1/targets' \
  | python3 -c "import sys,json; [print(t['labels'].get('job'), t['health']) for t in json.load(sys.stdin)['data']['activeTargets']]"

# Pokaż logi agenta z ostatnich 5 min
kubectl logs -n mcp deploy/langchain-agent --since=5m

# Usuń currency-knative (reset scenariuszy)
kubectl delete ksvc -n astronomy-shop currency-knative --ignore-not-found

# Teardown klastra
make teardown
```

---

## Kolejność scenariuszy

```
bootstrap → wstęp (shop) → sc.1 → sc.4 → sc.2 → sc.3 → sc.5 → sc.6 → sc.7
              (shop + deploy) (zero) (canary) (tuning) (diag) (roll) (alert)
```

Scenariusze 5 i 6 mogą być pokazane w dowolnej kolejności po sc.1.
Scenariusz 7 najlepiej na koniec — jest climaxem demo.

---

## Typowe problemy

| Problem | Rozwiązanie |
|---------|-------------|
| `make scenario-X` — agent nie odpowiada | `kubectl logs -n mcp deploy/langchain-agent -f` — sprawdź czy agent zainicjował się w pełni |
| Grafana nie ma danych | `make traffic` żeby wygenerować ruch, odczekaj 30s |
| Pod w `ImagePullBackOff` po sc.1 | Sprawdź czy `OTEL_METRICS_EXPORTER=none` jest w envach ksvc |
| `make grafana` — `no healthy upstream` | `kubectl rollout restart -n monitoring deploy/prom-grafana` |
| Bootstrap pada w fazie 5 (OTel webhook) | Skrypt sam retryuje 18x po 10s; poczekaj |
| Smoke test "0 Prometheus targets" | `make knative-restart` — przeładowuje config-observability w Knative |
