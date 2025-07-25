;; EcoFlow - Automated Carbon Tracking & Trading Platform
;; Smart contract for IoT-powered carbon offset verification and marketplace

;; Constants
(define-constant PLATFORM_ADMIN tx-sender)
(define-constant ERR_ACCESS_DENIED (err u200))
(define-constant ERR_DEVICE_NOT_FOUND (err u201))
(define-constant ERR_INSUFFICIENT_METRICS (err u202))
(define-constant ERR_TOKEN_NOT_FOUND (err u203))
(define-constant ERR_INVALID_QUANTITY (err u204))
(define-constant ERR_TRANSACTION_FAILED (err u205))
(define-constant ERR_DEVICE_INACTIVE (err u206))
(define-constant ERR_ALREADY_VERIFIED (err u207))

;; Data Variables
(define-data-var next-token-id uint u1)
(define-data-var next-device-id uint u1)
(define-data-var platform-fee-rate uint u25) ;; 2.5% platform fee

;; Data Maps
(define-map eco-devices 
    uint 
    {
        operator: principal,
        device-category: (string-ascii 64),
        geo-location: (string-ascii 128),
        emission-threshold: uint,
        is-online: bool,
        is-certified: bool,
        total-readings: uint
    }
)

(define-map environmental-metrics
    {device-id: uint, reading-timestamp: uint}
    {
        carbon-offset: uint,
        ambient-temp: uint,
        moisture-level: uint,
        is-validated: bool,
        confidence-score: uint
    }
)

(define-map offset-tokens
    uint
    {
        holder: principal,
        token-quantity: uint,
        source-device: uint,
        mint-timestamp: uint,
        market-price: uint,
        is-tradeable: bool,
        is-certified: bool,
        metadata-uri: (string-ascii 256)
    }
)

(define-map account-portfolios principal uint)
(define-map marketplace-listings uint bool)
(define-map device-operators principal (list 50 uint))

;; Private Functions
(define-private (is-platform-admin)
    (is-eq tx-sender PLATFORM_ADMIN)
)

(define-private (calculate-token-amount (offset-amount uint))
    (/ offset-amount u2000) ;; 1 token per 2000 units of carbon offset
)

(define-private (update-operator-devices (operator principal) (device-id uint))
    (let
        (
            (current-devices (default-to (list) (map-get? device-operators operator)))
        )
        (map-set device-operators operator 
            (unwrap-panic (as-max-len? (append current-devices device-id) u50))
        )
    )
)

;; Public Functions

;; Register a new environmental monitoring device
(define-public (register-eco-device (category (string-ascii 64)) (location (string-ascii 128)) (threshold uint))
    (let
        (
            (device-id (var-get next-device-id))
        )
        (map-set eco-devices device-id
            {
                operator: tx-sender,
                device-category: category,
                geo-location: location,
                emission-threshold: threshold,
                is-online: true,
                is-certified: false,
                total-readings: u0
            }
        )
        (update-operator-devices tx-sender device-id)
        (var-set next-device-id (+ device-id u1))
        (ok device-id)
    )
)

;; Certify device (admin only)
(define-public (certify-eco-device (device-id uint))
    (begin
        (asserts! (is-platform-admin) ERR_ACCESS_DENIED)
        (match (map-get? eco-devices device-id)
            device-info
            (begin
                (asserts! (not (get is-certified device-info)) ERR_ALREADY_VERIFIED)
                (map-set eco-devices device-id
                    (merge device-info {is-certified: true})
                )
                (ok true)
            )
            ERR_DEVICE_NOT_FOUND
        )
    )
)

;; Toggle device status
(define-public (toggle-device-status (device-id uint))
    (match (map-get? eco-devices device-id)
        device-info
        (begin
            (asserts! (is-eq (get operator device-info) tx-sender) ERR_ACCESS_DENIED)
            (map-set eco-devices device-id
                (merge device-info {is-online: (not (get is-online device-info))})
            )
            (ok true)
        )
        ERR_DEVICE_NOT_FOUND
    )
)

;; Submit environmental metrics
(define-public (submit-environmental-data (device-id uint) (carbon-offset uint) (temperature uint) (humidity uint) (confidence uint))
    (let
        (
            (device-opt (map-get? eco-devices device-id))
            (current-time (unwrap-panic (get-block-info? time (- block-height u1))))
        )
        (match device-opt
            device-info
            (begin
                (asserts! (is-eq (get operator device-info) tx-sender) ERR_ACCESS_DENIED)
                (asserts! (get is-online device-info) ERR_DEVICE_INACTIVE)
                
                ;; Store the metrics
                (map-set environmental-metrics 
                    {device-id: device-id, reading-timestamp: current-time}
                    {
                        carbon-offset: carbon-offset,
                        ambient-temp: temperature,
                        moisture-level: humidity,
                        is-validated: (get is-certified device-info),
                        confidence-score: confidence
                    }
                )
                
                ;; Update device reading count
                (map-set eco-devices device-id
                    (merge device-info {total-readings: (+ (get total-readings device-info) u1)})
                )
                
                ;; Auto-mint tokens if threshold is met and confidence is high
                (if (and 
                        (>= carbon-offset (get emission-threshold device-info))
                        (>= confidence u80))
                    (match (mint-offset-token device-id carbon-offset current-time)
                        success (ok success)
                        error (err error)
                    )
                    (ok device-id)
                )
            )
            ERR_DEVICE_NOT_FOUND
        )
    )
)

;; Mint carbon offset tokens
(define-private (mint-offset-token (device-id uint) (offset-amount uint) (timestamp uint))
    (let
        (
            (token-id (var-get next-token-id))
            (device-opt (map-get? eco-devices device-id))
        )
        (match device-opt
            device-info
            (let
                (
                    (tokens-to-mint (calculate-token-amount offset-amount))
                    (operator (get operator device-info))
                    (metadata-uri (concat "ecoflow://token/" (int-to-ascii token-id)))
                )
                (asserts! (> tokens-to-mint u0) ERR_INVALID_QUANTITY)
                
                (map-set offset-tokens token-id
                    {
                        holder: operator,
                        token-quantity: tokens-to-mint,
                        source-device: device-id,
                        mint-timestamp: timestamp,
                        market-price: u0,
                        is-tradeable: false,
                        is-certified: (get is-certified device-info),
                        metadata-uri: metadata-uri
                    }
                )
                
                ;; Update account portfolio
                (map-set account-portfolios operator 
                    (+ (default-to u0 (map-get? account-portfolios operator)) tokens-to-mint)
                )
                
                (var-set next-token-id (+ token-id u1))
                (ok token-id)
            )
            ERR_DEVICE_NOT_FOUND
        )
    )
)

;; List tokens for trading
(define-public (list-tokens-for-trade (token-id uint) (asking-price uint))
    (match (map-get? offset-tokens token-id)
        token-info
        (begin
            (asserts! (is-eq (get holder token-info) tx-sender) ERR_ACCESS_DENIED)
            (asserts! (> asking-price u0) ERR_INVALID_QUANTITY)
            (asserts! (get is-certified token-info) ERR_ACCESS_DENIED)
            
            (map-set offset-tokens token-id
                (merge token-info {market-price: asking-price, is-tradeable: true})
            )
            (map-set marketplace-listings token-id true)
            (ok true)
        )
        ERR_TOKEN_NOT_FOUND
    )
)

;; Purchase offset tokens
(define-public (purchase-offset-tokens (token-id uint))
    (match (map-get? offset-tokens token-id)
        token-info
        (let
            (
                (seller (get holder token-info))
                (price (get market-price token-info))
                (quantity (get token-quantity token-info))
                (platform-fee (/ (* price (var-get platform-fee-rate)) u1000))
            )
            (asserts! (get is-tradeable token-info) ERR_INVALID_QUANTITY)
            (asserts! (not (is-eq seller tx-sender)) ERR_ACCESS_DENIED)
            
            ;; Transfer token ownership
            (map-set offset-tokens token-id
                (merge token-info {holder: tx-sender, is-tradeable: false, market-price: u0})
            )
            
            ;; Update portfolios
            (map-set account-portfolios seller
                (- (default-to u0 (map-get? account-portfolios seller)) quantity)
            )
            (map-set account-portfolios tx-sender
                (+ (default-to u0 (map-get? account-portfolios tx-sender)) quantity)
            )
            
            ;; Remove from marketplace
            (map-delete marketplace-listings token-id)
            
            (ok true)
        )
        ERR_TOKEN_NOT_FOUND
    )
)

;; Batch mint tokens (admin only)
(define-public (batch-mint-tokens (recipients (list 10 principal)) (quantities (list 10 uint)))
    (begin
        (asserts! (is-platform-admin) ERR_ACCESS_DENIED)
        (asserts! (is-eq (len recipients) (len quantities)) ERR_INVALID_QUANTITY)
        
        (ok (map batch-mint-helper recipients quantities))
    )
)

(define-private (batch-mint-helper (recipient principal) (quantity uint))
    (let
        (
            (token-id (var-get next-token-id))
        )
        (map-set offset-tokens token-id
            {
                holder: recipient,
                token-quantity: quantity,
                source-device: u0,
                mint-timestamp: (unwrap-panic (get-block-info? time (- block-height u1))),
                market-price: u0,
                is-tradeable: false,
                is-certified: true,
                metadata-uri: "ecoflow://admin-mint"
            }
        )
        (map-set account-portfolios recipient 
            (+ (default-to u0 (map-get? account-portfolios recipient)) quantity)
        )
        (var-set next-token-id (+ token-id u1))
        token-id
    )
)

;; Update platform fee (admin only)
(define-public (update-platform-fee (new-fee-rate uint))
    (begin
        (asserts! (is-platform-admin) ERR_ACCESS_DENIED)
        (asserts! (<= new-fee-rate u100) ERR_INVALID_QUANTITY) ;; Max 10%
        (var-set platform-fee-rate new-fee-rate)
        (ok true)
    )
)

;; Read-only functions

(define-read-only (get-eco-device (device-id uint))
    (map-get? eco-devices device-id)
)

(define-read-only (get-environmental-data (device-id uint) (timestamp uint))
    (map-get? environmental-metrics {device-id: device-id, reading-timestamp: timestamp})
)

(define-read-only (get-offset-token (token-id uint))
    (map-get? offset-tokens token-id)
)

(define-read-only (get-account-portfolio (account principal))
    (default-to u0 (map-get? account-portfolios account))
)

(define-read-only (get-operator-devices (operator principal))
    (default-to (list) (map-get? device-operators operator))
)

(define-read-only (is-token-listed (token-id uint))
    (default-to false (map-get? marketplace-listings token-id))
)

(define-read-only (get-platform-stats)
    {
        total-devices: (var-get next-device-id),
        total-tokens: (var-get next-token-id),
        platform-fee: (var-get platform-fee-rate),
        admin: PLATFORM_ADMIN
    }
)

(define-read-only (get-next-token-id)
    (var-get next-token-id)
)

(define-read-only (get-next-device-id)
    (var-get next-device-id)
)