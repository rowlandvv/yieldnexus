;; Yield Nexus - Automated Yield Aggregator Protocol
;; Smart routing for optimal yields across multiple strategies with auto-compounding

;; Constants
(define-constant contract-owner tx-sender)
(define-constant err-unauthorized (err u100))
(define-constant err-insufficient-balance (err u101))
(define-constant err-invalid-amount (err u102))
(define-constant err-vault-full (err u103))
(define-constant err-strategy-inactive (err u104))
(define-constant err-withdrawal-locked (err u105))
(define-constant err-not-found (err u106))
(define-constant err-already-exists (err u107))
(define-constant err-paused (err u108))
(define-constant err-harvest-cooldown (err u109))
(define-constant err-max-strategies (err u110))

;; Protocol Parameters
(define-constant min-deposit u1000000) ;; 1 STX minimum
(define-constant max-vault-cap u1000000000000) ;; 1M STX cap
(define-constant performance-fee u200) ;; 2% performance fee
(define-constant management-fee u50) ;; 0.5% annual management fee
(define-constant withdrawal-fee u10) ;; 0.1% withdrawal fee
(define-constant harvest-cooldown u144) ;; ~24 hours between harvests
(define-constant max-strategies-per-vault u10)
(define-constant emergency-withdrawal-penalty u500) ;; 5% emergency withdrawal

;; Strategy Risk Levels
(define-constant risk-conservative u1)
(define-constant risk-moderate u2)
(define-constant risk-aggressive u3)

;; Data Variables
(define-data-var total-value-locked uint u0)
(define-data-var total-yield-generated uint u0)
(define-data-var vault-counter uint u0)
(define-data-var strategy-counter uint u0)
(define-data-var harvest-counter uint u0)
(define-data-var protocol-revenue uint u0)
(define-data-var paused bool false)
(define-data-var last-harvest-block uint u0)

;; Vault Data
(define-map vaults
    uint ;; vault-id
    {
        name: (string-ascii 50),
        total-deposits: uint,
        total-shares: uint,
        risk-level: uint,
        active-strategies: uint,
        performance: uint,
        created-at: uint,
        last-harvest: uint,
        locked: bool
    }
)

;; User Positions
(define-map user-positions
    { vault-id: uint, user: principal }
    {
        shares: uint,
        deposited: uint,
        earned: uint,
        last-action: uint,
        lock-until: uint
    }
)

;; Strategies
(define-map strategies
    uint ;; strategy-id
    {
        name: (string-ascii 50),
        vault-id: uint,
        allocation-percent: uint,
        current-balance: uint,
        total-returns: uint,
        risk-level: uint,
        active: bool,
        last-update: uint
    }
)

;; Harvest Records
(define-map harvests
    uint ;; harvest-id
    {
        vault-id: uint,
        yield-amount: uint,
        performance-fee: uint,
        timestamp: uint,
        caller: principal
    }
)

;; User Stats
(define-map user-stats
    principal
    {
        total-deposited: uint,
        total-withdrawn: uint,
        total-earned: uint,
        vaults-entered: uint,
        first-deposit: uint
    }
)

;; Strategy Performance
(define-map strategy-performance
    { strategy-id: uint, period: uint }
    {
        returns: uint,
        apy: uint,
        volatility: uint
    }
)

;; Private Functions
(define-private (calculate-shares (amount uint) (total-deposits uint) (total-shares uint))
    (if (is-eq total-shares u0)
        amount
        (/ (* amount total-shares) total-deposits)
    )
)

(define-private (calculate-withdrawal (shares uint) (total-deposits uint) (total-shares uint))
    (if (is-eq total-shares u0)
        u0
        (/ (* shares total-deposits) total-shares)
    )
)

(define-private (calculate-performance-fee (profit uint))
    (/ (* profit performance-fee) u10000)
)

(define-private (calculate-management-fee (amount uint) (blocks uint))
    (/ (* (* amount management-fee) blocks) (* u10000 u52560))
)

(define-private (calculate-withdrawal-fee (amount uint))
    (/ (* amount withdrawal-fee) u10000)
)

(define-private (min (a uint) (b uint))
    (if (< a b) a b)
)

(define-private (max (a uint) (b uint))
    (if (> a b) a b)
)

;; Read-Only Functions
(define-read-only (get-vault (vault-id uint))
    (map-get? vaults vault-id)
)

(define-read-only (get-user-position (vault-id uint) (user principal))
    (map-get? user-positions { vault-id: vault-id, user: user })
)

(define-read-only (get-strategy (strategy-id uint))
    (map-get? strategies strategy-id)
)

(define-read-only (get-user-stats (user principal))
    (default-to
        { total-deposited: u0, total-withdrawn: u0, total-earned: u0, vaults-entered: u0, first-deposit: u0 }
        (map-get? user-stats user)
    )
)

(define-read-only (get-total-value-locked)
    (var-get total-value-locked)
)

(define-read-only (get-vault-apy (vault-id uint))
    (match (map-get? vaults vault-id)
        vault
        (if (is-eq (get total-deposits vault) u0)
            u0
            (/ (* (get performance vault) u10000) (get total-deposits vault))
        )
        u0
    )
)

(define-read-only (get-user-balance (vault-id uint) (user principal))
    (match (map-get? user-positions { vault-id: vault-id, user: user })
        position
        (match (map-get? vaults vault-id)
            vault
            (calculate-withdrawal (get shares position) (get total-deposits vault) (get total-shares vault))
            u0
        )
        u0
    )
)

(define-read-only (get-protocol-revenue)
    (var-get protocol-revenue)
)

(define-read-only (can-harvest)
    (>= (- u1 (var-get last-harvest-block)) harvest-cooldown)
)

;; Public Functions

;; Create new vault
(define-public (create-vault (name (string-ascii 50)) (risk-level uint))
    (let
        (
            (vault-id (+ (var-get vault-counter) u1))
        )
        ;; Validations
        (asserts! (is-eq tx-sender contract-owner) err-unauthorized)
        (asserts! (<= risk-level risk-aggressive) err-invalid-amount)
        (asserts! (> (len name) u0) err-invalid-amount)
        
        ;; Create vault
        (map-set vaults vault-id {
            name: name,
            total-deposits: u0,
            total-shares: u0,
            risk-level: risk-level,
            active-strategies: u0,
            performance: u0,
            created-at: u1,
            last-harvest: u0,
            locked: false
        })
        
        (var-set vault-counter vault-id)
        (ok vault-id)
    )
)

;; Deposit into vault
(define-public (deposit (vault-id uint) (amount uint))
    (let
        (
            (user tx-sender)
            (vault (unwrap! (map-get? vaults vault-id) err-not-found))
            (shares-to-mint (calculate-shares amount (get total-deposits vault) (get total-shares vault)))
            (existing-position (map-get? user-positions { vault-id: vault-id, user: user }))
        )
        ;; Validations
        (asserts! (not (var-get paused)) err-paused)
        (asserts! (not (get locked vault)) err-vault-full)
        (asserts! (>= amount min-deposit) err-invalid-amount)
        (asserts! (<= (+ (get total-deposits vault) amount) max-vault-cap) err-vault-full)
        (asserts! (>= (stx-get-balance user) amount) err-insufficient-balance)
        
        ;; Transfer STX to contract
        (try! (stx-transfer? amount user (as-contract tx-sender)))
        
        ;; Update or create position
        (match existing-position
            position
            (map-set user-positions { vault-id: vault-id, user: user } {
                shares: (+ (get shares position) shares-to-mint),
                deposited: (+ (get deposited position) amount),
                earned: (get earned position),
                last-action: u1,
                lock-until: u0
            })
            (map-set user-positions { vault-id: vault-id, user: user } {
                shares: shares-to-mint,
                deposited: amount,
                earned: u0,
                last-action: u1,
                lock-until: u0
            })
        )
        
        ;; Update vault
        (map-set vaults vault-id (merge vault {
            total-deposits: (+ (get total-deposits vault) amount),
            total-shares: (+ (get total-shares vault) shares-to-mint)
        }))
        
        ;; Update user stats
        (let
            (
                (stats (get-user-stats user))
                (is-new-vault (is-none existing-position))
            )
            (map-set user-stats user {
                total-deposited: (+ (get total-deposited stats) amount),
                total-withdrawn: (get total-withdrawn stats),
                total-earned: (get total-earned stats),
                vaults-entered: (if is-new-vault (+ (get vaults-entered stats) u1) (get vaults-entered stats)),
                first-deposit: (if (is-eq (get first-deposit stats) u0) u1 (get first-deposit stats))
            })
        )
        
        ;; Update TVL
        (var-set total-value-locked (+ (var-get total-value-locked) amount))
        
        (ok shares-to-mint)
    )
)

;; Withdraw from vault
(define-public (withdraw (vault-id uint) (shares uint))
    (let
        (
            (user tx-sender)
            (vault (unwrap! (map-get? vaults vault-id) err-not-found))
            (position (unwrap! (map-get? user-positions { vault-id: vault-id, user: user }) err-not-found))
            (withdrawal-amount (calculate-withdrawal shares (get total-deposits vault) (get total-shares vault)))
            (fee (calculate-withdrawal-fee withdrawal-amount))
            (net-amount (- withdrawal-amount fee))
        )
        ;; Validations
        (asserts! (not (var-get paused)) err-paused)
        (asserts! (<= shares (get shares position)) err-insufficient-balance)
        (asserts! (> shares u0) err-invalid-amount)
        (asserts! (>= u1 (get lock-until position)) err-withdrawal-locked)
        
        ;; Transfer STX to user
        (try! (as-contract (stx-transfer? net-amount tx-sender user)))
        
        ;; Update position
        (if (is-eq shares (get shares position))
            ;; Full withdrawal - remove position
            (map-delete user-positions { vault-id: vault-id, user: user })
            ;; Partial withdrawal - update position
            (map-set user-positions { vault-id: vault-id, user: user } (merge position {
                shares: (- (get shares position) shares),
                last-action: u1
            }))
        )
        
        ;; Update vault
        (map-set vaults vault-id (merge vault {
            total-deposits: (- (get total-deposits vault) withdrawal-amount),
            total-shares: (- (get total-shares vault) shares)
        }))
        
        ;; Update user stats
        (let ((stats (get-user-stats user)))
            (map-set user-stats user (merge stats {
                total-withdrawn: (+ (get total-withdrawn stats) net-amount)
            }))
        )
        
        ;; Update globals
        (var-set total-value-locked (- (var-get total-value-locked) withdrawal-amount))
        (var-set protocol-revenue (+ (var-get protocol-revenue) fee))
        
        (ok net-amount)
    )
)

;; Harvest yields from strategies
(define-public (harvest (vault-id uint))
    (let
        (
            (vault (unwrap! (map-get? vaults vault-id) err-not-found))
            (harvest-id (+ (var-get harvest-counter) u1))
            ;; Simulated yield (in production, this would aggregate from actual strategies)
            (yield-amount (/ (* (get total-deposits vault) u300) u10000)) ;; 3% yield
            (perf-fee (calculate-performance-fee yield-amount))
            (net-yield (- yield-amount perf-fee))
        )
        ;; Validations
        (asserts! (not (var-get paused)) err-paused)
        (asserts! (can-harvest) err-harvest-cooldown)
        
        ;; Record harvest
        (map-set harvests harvest-id {
            vault-id: vault-id,
            yield-amount: yield-amount,
            performance-fee: perf-fee,
            timestamp: u1,
            caller: tx-sender
        })
        
        ;; Update vault with new performance
        (map-set vaults vault-id (merge vault {
            total-deposits: (+ (get total-deposits vault) net-yield),
            performance: (+ (get performance vault) net-yield),
            last-harvest: u1
        }))
        
        ;; Update globals
        (var-set harvest-counter harvest-id)
        (var-set last-harvest-block u1)
        (var-set total-yield-generated (+ (var-get total-yield-generated) yield-amount))
        (var-set protocol-revenue (+ (var-get protocol-revenue) perf-fee))
        
        (ok { yield: yield-amount, fee: perf-fee, net: net-yield })
    )
)

;; Add strategy to vault
(define-public (add-strategy (vault-id uint) (name (string-ascii 50)) (allocation uint) (risk uint))
    (let
        (
            (vault (unwrap! (map-get? vaults vault-id) err-not-found))
            (strategy-id (+ (var-get strategy-counter) u1))
        )
        ;; Validations
        (asserts! (is-eq tx-sender contract-owner) err-unauthorized)
        (asserts! (< (get active-strategies vault) max-strategies-per-vault) err-max-strategies)
        (asserts! (<= allocation u10000) err-invalid-amount) ;; Max 100%
        (asserts! (<= risk risk-aggressive) err-invalid-amount)
        
        ;; Create strategy
        (map-set strategies strategy-id {
            name: name,
            vault-id: vault-id,
            allocation-percent: allocation,
            current-balance: u0,
            total-returns: u0,
            risk-level: risk,
            active: true,
            last-update: u1
        })
        
        ;; Update vault
        (map-set vaults vault-id (merge vault {
            active-strategies: (+ (get active-strategies vault) u1)
        }))
        
        (var-set strategy-counter strategy-id)
        (ok strategy-id)
    )
)

;; Rebalance vault allocations
(define-public (rebalance (vault-id uint))
    (let
        (
            (vault (unwrap! (map-get? vaults vault-id) err-not-found))
        )
        ;; Validations
        (asserts! (is-eq tx-sender contract-owner) err-unauthorized)
        (asserts! (not (var-get paused)) err-paused)
        
        ;; In production, this would:
        ;; 1. Calculate optimal allocations based on strategy performance
        ;; 2. Move funds between strategies
        ;; 3. Update strategy balances
        
        ;; For now, just update the last harvest time
        (map-set vaults vault-id (merge vault {
            last-harvest: u1
        }))
        
        (ok true)
    )
)

;; Emergency withdraw (with penalty)
(define-public (emergency-withdraw (vault-id uint))
    (let
        (
            (user tx-sender)
            (position (unwrap! (map-get? user-positions { vault-id: vault-id, user: user }) err-not-found))
            (vault (unwrap! (map-get? vaults vault-id) err-not-found))
            (withdrawal-amount (calculate-withdrawal (get shares position) (get total-deposits vault) (get total-shares vault)))
            (penalty (/ (* withdrawal-amount emergency-withdrawal-penalty) u10000))
            (net-amount (- withdrawal-amount penalty))
        )
        ;; Transfer with penalty
        (try! (as-contract (stx-transfer? net-amount tx-sender user)))
        
        ;; Remove position
        (map-delete user-positions { vault-id: vault-id, user: user })
        
        ;; Update vault
        (map-set vaults vault-id (merge vault {
            total-deposits: (- (get total-deposits vault) withdrawal-amount),
            total-shares: (- (get total-shares vault) (get shares position))
        }))
        
        ;; Update stats
        (let ((stats (get-user-stats user)))
            (map-set user-stats user (merge stats {
                total-withdrawn: (+ (get total-withdrawn stats) net-amount)
            }))
        )
        
        ;; Update globals
        (var-set total-value-locked (- (var-get total-value-locked) withdrawal-amount))
        (var-set protocol-revenue (+ (var-get protocol-revenue) penalty))
        
        (ok net-amount)
    )
)

;; Compound earnings back into vault
(define-public (compound (vault-id uint))
    (let
        (
            (user tx-sender)
            (position (unwrap! (map-get? user-positions { vault-id: vault-id, user: user }) err-not-found))
            (vault (unwrap! (map-get? vaults vault-id) err-not-found))
            (current-value (calculate-withdrawal (get shares position) (get total-deposits vault) (get total-shares vault)))
            (earnings (- current-value (get deposited position)))
        )
        ;; Validations
        (asserts! (> earnings u0) err-invalid-amount)
        
        ;; Update position to mark earnings as compounded
        (map-set user-positions { vault-id: vault-id, user: user } (merge position {
            deposited: current-value,
            earned: (+ (get earned position) earnings),
            last-action: u1
        }))
        
        ;; Update user stats
        (let ((stats (get-user-stats user)))
            (map-set user-stats user (merge stats {
                total-earned: (+ (get total-earned stats) earnings)
            }))
        )
        
        (ok earnings)
    )
)

;; Admin Functions

;; Set vault lock status
(define-public (set-vault-lock (vault-id uint) (locked bool))
    (let
        (
            (vault (unwrap! (map-get? vaults vault-id) err-not-found))
        )
        (asserts! (is-eq tx-sender contract-owner) err-unauthorized)
        
        (map-set vaults vault-id (merge vault {
            locked: locked
        }))
        
        (ok locked)
    )
)

;; Update strategy allocation
(define-public (update-strategy-allocation (strategy-id uint) (new-allocation uint))
    (let
        (
            (strategy (unwrap! (map-get? strategies strategy-id) err-not-found))
        )
        (asserts! (is-eq tx-sender contract-owner) err-unauthorized)
        (asserts! (<= new-allocation u10000) err-invalid-amount)
        
        (map-set strategies strategy-id (merge strategy {
            allocation-percent: new-allocation,
            last-update: u1
        }))
        
        (ok new-allocation)
    )
)

;; Pause/Resume protocol
(define-public (set-pause-state (pause bool))
    (begin
        (asserts! (is-eq tx-sender contract-owner) err-unauthorized)
        (var-set paused pause)
        (ok pause)
    )
)

;; Withdraw protocol fees
(define-public (withdraw-fees (amount uint))
    (begin
        (asserts! (is-eq tx-sender contract-owner) err-unauthorized)
        (asserts! (<= amount (var-get protocol-revenue)) err-insufficient-balance)
        
        (try! (as-contract (stx-transfer? amount tx-sender contract-owner)))
        (var-set protocol-revenue (- (var-get protocol-revenue) amount))
        
        (ok amount)
    )
)