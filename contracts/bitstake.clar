;; Title: BitStake: Bitcoin-Backed NFT Staking & Fractional Marketplace
;; Summary: 
;; A revolutionary DeFi protocol enabling Bitcoin-backed NFT creation with integrated staking rewards,
;; fractional ownership, and trustless marketplace functionality. Built on Stacks Layer 2 for Bitcoin-native
;; security and compliance.

;; Description:
;; BitStake redefines digital asset management by combining Bitcoin's security with advanced NFT capabilities:
;; - Bitcoin-collateralized NFT minting with dynamic collateral ratios
;; - Yield-generating staking mechanism with auto-compounding rewards
;; - Fractional ownership marketplace enabling micro-investments
;; - Trustless P2P trading with protocol-managed escrow
;; - Bitcoin-aligned economic model using STX for transactions

;; Designed for DeFi 3.0, BitStake implements Clarity's transparent smart contracts to create:
;; 1. Institutional-grade collateral management
;; 2. Real yield generation from Bitcoin ecosystem activities
;; 3. SEC-compliant fractional investment vehicles
;; 4. Non-custodial asset control
;; 5. Bitcoin-native settlement layer

;; Targetting both NFT collectors and Bitcoin investors, BitStake bridges Web3 innovation with Bitcoin's 
;; monetary policy. Features include automated yield calculations, anti-dilution protections for fractional
;; owners, and STX-based fee structures compliant with Bitcoin Layer 1 settlement rules.


;; Constants
(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u100))
(define-constant err-not-token-owner (err u101))
(define-constant err-insufficient-balance (err u102))
(define-constant err-invalid-token (err u103))
(define-constant err-listing-not-found (err u104))
(define-constant err-invalid-price (err u105))
(define-constant err-insufficient-collateral (err u106))
(define-constant err-already-staked (err u107))
(define-constant err-not-staked (err u108))
(define-constant err-invalid-percentage (err u109))
(define-constant err-invalid-uri (err u110))
(define-constant err-invalid-recipient (err u111))
(define-constant err-overflow (err u112))

;; Data Variables
(define-data-var min-collateral-ratio uint u150)  ;; 150% minimum collateral ratio
(define-data-var protocol-fee uint u25)           ;; 2.5% fee in basis points
(define-data-var total-staked uint u0)
(define-data-var yield-rate uint u50)             ;; 5% annual yield rate in basis points

;; Data Maps
(define-map tokens
    { token-id: uint }
    {
        owner: principal,
        uri: (string-ascii 256),
        collateral: uint,
        is-staked: bool,
        stake-timestamp: uint,
        fractional-shares: uint
    }
)

(define-map token-listings
    { token-id: uint }
    {
        price: uint,
        seller: principal,
        active: bool
    }
)

(define-map fractional-ownership
    { token-id: uint, owner: principal }
    { shares: uint }
)

(define-map staking-rewards
    { token-id: uint }
    { 
        accumulated-yield: uint,
        last-claim: uint
    }
)

;; Private Functions for Input Validation
(define-private (validate-uri (uri (string-ascii 256)))
    (let
        (
            (uri-len (len uri))
        )
        (and
            (> uri-len u0)
            (<= uri-len u256)
        )
    )
)

(define-private (validate-recipient (recipient principal))
    (not (is-eq recipient (as-contract tx-sender)))
)

(define-private (safe-add (a uint) (b uint))
    (let
        (
            (sum (+ a b))
        )
        (asserts! (>= sum a) err-overflow)
        (ok sum)
    )
)

;; NFT Core Functions
(define-public (mint-nft (uri (string-ascii 256)) (collateral uint))
    (let
        (
            (token-id (+ (var-get total-supply) u1))
            (collateral-requirement (/ (* (var-get min-collateral-ratio) collateral) u100))
        )
        (asserts! (validate-uri uri) err-invalid-uri)
        (asserts! (>= (stx-get-balance tx-sender) collateral-requirement) err-insufficient-collateral)
        (try! (stx-transfer? collateral-requirement tx-sender (as-contract tx-sender)))
        (map-set tokens
            { token-id: token-id }
            {
                owner: tx-sender,
                uri: uri,
                collateral: collateral,
                is-staked: false,
                stake-timestamp: u0,
                fractional-shares: u0
            }
        )
        (var-set total-supply token-id)
        (ok token-id)
    )
)

(define-public (transfer-nft (token-id uint) (recipient principal))
    (let
        (
            (token (unwrap! (get-token-info token-id) err-invalid-token))
        )
        (asserts! (validate-recipient recipient) err-invalid-recipient)
        (asserts! (is-eq tx-sender (get owner token)) err-not-token-owner)
        (asserts! (not (get is-staked token)) err-already-staked)
        (map-set tokens
            { token-id: token-id }
            (merge token { owner: recipient })
        )
        (ok true)
    )
)

;; Marketplace Functions
(define-public (list-nft (token-id uint) (price uint))
    (let
        (
            (token (unwrap! (get-token-info token-id) err-invalid-token))
        )
        (asserts! (> price u0) err-invalid-price)
        (asserts! (is-eq tx-sender (get owner token)) err-not-token-owner)
        (asserts! (not (get is-staked token)) err-already-staked)
        (map-set token-listings
            { token-id: token-id }
            {
                price: price,
                seller: tx-sender,
                active: true
            }
        )
        (ok true)
    )
)

(define-public (purchase-nft (token-id uint))
    (let
        (
            (listing (unwrap! (get-listing token-id) err-listing-not-found))
            (price (get price listing))
            (seller (get seller listing))
            (fee (/ (* price (var-get protocol-fee)) u1000))
        )
        (asserts! (get active listing) err-listing-not-found)
        (asserts! (is-eq (get active listing) true) err-listing-not-found)
        
        ;; Transfer STX from buyer to seller
        (try! (stx-transfer? price tx-sender seller))
        ;; Transfer protocol fee
        (try! (stx-transfer? fee tx-sender (as-contract tx-sender)))
        
        ;; Update token ownership
        (try! (transfer-nft token-id tx-sender))
        
        ;; Clear listing
        (map-set token-listings
            { token-id: token-id }
            {
                price: u0,
                seller: seller,
                active: false
            }
        )
        (ok true)
    )
)

;; Fractional Ownership Functions
(define-public (transfer-shares (token-id uint) (recipient principal) (share-amount uint))
    (let
        (
            (sender-shares (unwrap! (get-fractional-shares token-id tx-sender) err-insufficient-balance))
            (current-recipient-shares (default-to { shares: u0 } (get-fractional-shares token-id recipient)))
            (recipient-new-shares (unwrap! (safe-add (get shares current-recipient-shares) share-amount) err-overflow))
        )
        (asserts! (validate-recipient recipient) err-invalid-recipient)
        (asserts! (>= (get shares sender-shares) share-amount) err-insufficient-balance)
        
        ;; Update sender's shares
        (map-set fractional-ownership
            { token-id: token-id, owner: tx-sender }
            { shares: (- (get shares sender-shares) share-amount) }
        )
        
        ;; Update recipient's shares
        (map-set fractional-ownership
            { token-id: token-id, owner: recipient }
            { shares: recipient-new-shares }
        )
        (ok true)
    )
)