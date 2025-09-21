;; MediCert Medical Credentials NFT Contract
;; Implements SIP-009 NFT standard for medical credential verification
;; Manages minting, burning, and transfer of medical credential NFTs

;; SIP-009 NFT standard implementation (without external trait dependency)

;; Constants
(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u100))
(define-constant err-not-token-owner (err u101))
(define-constant err-not-found (err u102))
(define-constant err-token-exists (err u103))
(define-constant err-not-authorized-issuer (err u104))
(define-constant err-credential-revoked (err u105))
(define-constant err-invalid-credential-type (err u106))
(define-constant err-expired-credential (err u107))
(define-constant err-transfer-not-allowed (err u108))

;; Credential Types
(define-constant credential-type-md u1)       ;; Medical Doctor
(define-constant credential-type-rn u2)       ;; Registered Nurse  
(define-constant credential-type-np u3)       ;; Nurse Practitioner
(define-constant credential-type-pa u4)       ;; Physician Assistant
(define-constant credential-type-specialist u5) ;; Medical Specialist
(define-constant credential-type-tech u6)     ;; Medical Technician

;; Data Variables
(define-data-var last-token-id uint u0)
(define-data-var total-supply uint u0)
(define-data-var contract-uri (optional (string-utf8 256)) none)
(define-data-var token-transfer-enabled bool true)

;; NFT Definition
(define-non-fungible-token medical-credential uint)

;; Data Maps
(define-map credential-metadata
  { token-id: uint }
  {
    credential-type: uint,
    issuer: principal,
    issued-date: uint,
    expiration-date: uint,
    license-number: (string-ascii 50),
    specialty: (string-ascii 100),
    institution: (string-ascii 100),
    revoked: bool,
    metadata-uri: (optional (string-utf8 256))
  }
)

(define-map authorized-issuers
  { issuer: principal }
  {
    name: (string-ascii 100),
    authorized: bool,
    authorization-date: uint,
    issuer-type: uint ;; 1=hospital, 2=medical-board, 3=university, 4=government
  }
)

(define-map credential-history
  { token-id: uint, event-id: uint }
  {
    event-type: uint, ;; 1=minted, 2=transferred, 3=revoked, 4=renewed
    timestamp: uint,
    actor: principal,
    details: (optional (string-ascii 256))
  }
)

(define-map credential-event-count
  { token-id: uint }
  { count: uint }
)

(define-map issuer-statistics
  { issuer: principal }
  {
    total-issued: uint,
    total-active: uint,
    total-revoked: uint
  }
)

;; SIP-009 Required Functions

;; Get last token ID
(define-read-only (get-last-token-id)
  (ok (var-get last-token-id))
)

;; Get token URI
(define-read-only (get-token-uri (token-id uint))
  (match (map-get? credential-metadata { token-id: token-id })
    metadata (ok (get metadata-uri metadata))
    (err err-not-found)
  )
)

;; Get owner of token
(define-read-only (get-owner (token-id uint))
  (ok (nft-get-owner? medical-credential token-id))
)

;; Transfer token
(define-public (transfer (token-id uint) (sender principal) (recipient principal))
  (begin
    (asserts! (var-get token-transfer-enabled) err-transfer-not-allowed)
    (asserts! (is-eq tx-sender sender) err-not-token-owner)
    (asserts! (not (is-credential-revoked token-id)) err-credential-revoked)
    (try! (nft-transfer? medical-credential token-id sender recipient))
    (add-credential-event token-id u2 tx-sender (some "Credential transferred"))
    (ok true)
  )
)

;; Public Functions

;; Mint new medical credential NFT
(define-public (mint-credential
  (recipient principal)
  (credential-type uint)
  (expiration-date uint)
  (license-number (string-ascii 50))
  (specialty (string-ascii 100))
  (institution (string-ascii 100))
  (metadata-uri (optional (string-utf8 256)))
)
  (let (
    (token-id (+ (var-get last-token-id) u1))
    (issuer tx-sender)
    (current-block stacks-block-height)
  )
    (asserts! (is-authorized-issuer issuer) err-not-authorized-issuer)
    (asserts! (is-valid-credential-type credential-type) err-invalid-credential-type)
    (asserts! (> expiration-date current-block) err-expired-credential)
    (asserts! (> (len license-number) u0) (err u109))
    (asserts! (> (len specialty) u0) (err u110))
    (asserts! (> (len institution) u0) (err u111))
    
    ;; Mint the NFT
    (try! (nft-mint? medical-credential token-id recipient))
    
    ;; Store credential metadata
    (map-set credential-metadata
      { token-id: token-id }
      {
        credential-type: credential-type,
        issuer: issuer,
        issued-date: current-block,
        expiration-date: expiration-date,
        license-number: license-number,
        specialty: specialty,
        institution: institution,
        revoked: false,
        metadata-uri: metadata-uri
      }
    )
    
    ;; Initialize event tracking
    (map-set credential-event-count { token-id: token-id } { count: u0 })
    
    ;; Add mint event to history
    (add-credential-event token-id u1 issuer (some "Credential minted"))
    
    ;; Update issuer statistics
    (update-issuer-stats issuer u1 u0)
    
    ;; Update contract state
    (var-set last-token-id token-id)
    (var-set total-supply (+ (var-get total-supply) u1))
    
    (ok token-id)
  )
)

;; Revoke credential
(define-public (revoke-credential (token-id uint) (reason (string-ascii 256)))
  (let (
    (metadata (unwrap! (map-get? credential-metadata { token-id: token-id }) err-not-found))
    (issuer (get issuer metadata))
  )
    (asserts! (or (is-eq tx-sender issuer) (is-eq tx-sender contract-owner)) err-not-authorized-issuer)
    (asserts! (not (get revoked metadata)) err-credential-revoked)
    
    ;; Update credential as revoked
    (map-set credential-metadata
      { token-id: token-id }
      (merge metadata { revoked: true })
    )
    
    ;; Add revocation event
    (add-credential-event token-id u3 tx-sender (some reason))
    
    ;; Update issuer statistics
    (update-issuer-stats issuer u0 u1)
    
    (ok true)
  )
)

;; Burn credential (only by owner)
(define-public (burn-credential (token-id uint))
  (let (
    (owner (unwrap! (nft-get-owner? medical-credential token-id) err-not-found))
  )
    (asserts! (is-eq tx-sender owner) err-not-token-owner)
    (try! (nft-burn? medical-credential token-id owner))
    
    ;; Remove metadata
    (map-delete credential-metadata { token-id: token-id })
    
    ;; Update total supply
    (var-set total-supply (- (var-get total-supply) u1))
    
    (ok true)
  )
)

;; Register authorized issuer (owner only)
(define-public (register-issuer
  (issuer principal)
  (name (string-ascii 100))
  (issuer-type uint)
)
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (asserts! (> (len name) u0) (err u112))
    (asserts! (and (>= issuer-type u1) (<= issuer-type u4)) (err u113))
    
    (map-set authorized-issuers
      { issuer: issuer }
      {
        name: name,
        authorized: true,
        authorization-date: stacks-block-height,
        issuer-type: issuer-type
      }
    )
    
    ;; Initialize issuer statistics
    (map-set issuer-statistics
      { issuer: issuer }
      {
        total-issued: u0,
        total-active: u0,
        total-revoked: u0
      }
    )
    
    (ok true)
  )
)

;; Revoke issuer authorization (owner only)
(define-public (revoke-issuer-authorization (issuer principal))
  (let (
    (issuer-info (unwrap! (map-get? authorized-issuers { issuer: issuer }) err-not-found))
  )
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    
    (map-set authorized-issuers
      { issuer: issuer }
      (merge issuer-info { authorized: false })
    )
    
    (ok true)
  )
)

;; Toggle credential transfers (owner only)
(define-public (toggle-transfers)
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (var-set token-transfer-enabled (not (var-get token-transfer-enabled)))
    (ok (var-get token-transfer-enabled))
  )
)

;; Read-Only Functions

;; Get credential metadata
(define-read-only (get-credential-info (token-id uint))
  (map-get? credential-metadata { token-id: token-id })
)

;; Check if credential is valid (not expired and not revoked)
(define-read-only (is-credential-valid (token-id uint))
  (match (map-get? credential-metadata { token-id: token-id })
    metadata
    (and
      (not (get revoked metadata))
      (> (get expiration-date metadata) stacks-block-height)
    )
    false
  )
)

;; Check if credential is revoked
(define-read-only (is-credential-revoked (token-id uint))
  (match (map-get? credential-metadata { token-id: token-id })
    metadata (get revoked metadata)
    false
  )
)

;; Get authorized issuer info
(define-read-only (get-issuer-info (issuer principal))
  (map-get? authorized-issuers { issuer: issuer })
)

;; Get issuer statistics
(define-read-only (get-issuer-stats (issuer principal))
  (map-get? issuer-statistics { issuer: issuer })
)

;; Get credential event history
(define-read-only (get-credential-event (token-id uint) (event-id uint))
  (map-get? credential-history { token-id: token-id, event-id: event-id })
)

;; Get total supply
(define-read-only (get-total-supply)
  (ok (var-get total-supply))
)

;; Get contract info
(define-read-only (get-contract-info)
  {
    total-supply: (var-get total-supply),
    last-token-id: (var-get last-token-id),
    transfer-enabled: (var-get token-transfer-enabled),
    contract-owner: contract-owner
  }
)

;; Private Functions

;; Check if issuer is authorized
(define-private (is-authorized-issuer (issuer principal))
  (match (map-get? authorized-issuers { issuer: issuer })
    issuer-info (get authorized issuer-info)
    false
  )
)

;; Validate credential type
(define-private (is-valid-credential-type (credential-type uint))
  (and (>= credential-type u1) (<= credential-type u6))
)

;; Add event to credential history
(define-private (add-credential-event 
  (token-id uint) 
  (event-type uint) 
  (actor principal) 
  (details (optional (string-ascii 256)))
)
  (let (
    (current-count (default-to u0 (get count (map-get? credential-event-count { token-id: token-id }))))
    (event-id current-count)
  )
    (map-set credential-history
      { token-id: token-id, event-id: event-id }
      {
        event-type: event-type,
        timestamp: stacks-block-height,
        actor: actor,
        details: details
      }
    )
    (map-set credential-event-count 
      { token-id: token-id } 
      { count: (+ current-count u1) }
    )
    true
  )
)

;; Update issuer statistics
(define-private (update-issuer-stats (issuer principal) (new-issued uint) (new-revoked uint))
  (let (
    (current-stats (default-to 
      { total-issued: u0, total-active: u0, total-revoked: u0 }
      (map-get? issuer-statistics { issuer: issuer })
    ))
  )
    (map-set issuer-statistics
      { issuer: issuer }
      {
        total-issued: (+ (get total-issued current-stats) new-issued),
        total-active: (+ (get total-active current-stats) new-issued),
        total-revoked: (+ (get total-revoked current-stats) new-revoked)
      }
    )
    true
  )
)
