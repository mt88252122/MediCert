;; MediCert Credential Verifier Contract
;; Handles verification logic and issuer management for medical credentials
;; Provides public verification endpoints and credential validation services

;; Constants
(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u200))
(define-constant err-not-found (err u201))
(define-constant err-already-exists (err u202))
(define-constant err-unauthorized (err u203))
(define-constant err-invalid-verification-level (err u204))
(define-constant err-verification-expired (err u205))
(define-constant err-insufficient-fee (err u206))
(define-constant err-invalid-credential-type (err u207))
(define-constant err-verification-failed (err u208))

;; Verification Levels
(define-constant verification-level-basic u1)     ;; Basic identity check
(define-constant verification-level-standard u2)  ;; Standard professional verification
(define-constant verification-level-premium u3)   ;; Premium with background check
(define-constant verification-level-enhanced u4)  ;; Enhanced with continuous monitoring

;; Verification Fees (in microSTX)
(define-constant basic-verification-fee u1000000)    ;; 1 STX
(define-constant standard-verification-fee u2500000) ;; 2.5 STX
(define-constant premium-verification-fee u5000000)  ;; 5 STX
(define-constant enhanced-verification-fee u10000000) ;; 10 STX

;; Credential Status Constants
(define-constant status-pending u1)
(define-constant status-verified u2)
(define-constant status-rejected u3)
(define-constant status-suspended u4)
(define-constant status-expired u5)

;; Data Variables
(define-data-var next-verification-id uint u1)
(define-data-var contract-balance uint u0)
(define-data-var verification-enabled bool true)
(define-data-var minimum-verification-level uint u1)
(define-data-var total-verifications uint u0)

;; Data Maps
(define-map verification-requests
  { verification-id: uint }
  {
    credential-holder: principal,
    credential-type: uint,
    verification-level: uint,
    status: uint,
    requested-date: uint,
    processed-date: (optional uint),
    verifier: (optional principal),
    fee-paid: uint,
    expiration-date: uint,
    verification-data: (optional (string-ascii 500)),
    rejection-reason: (optional (string-ascii 256))
  }
)

(define-map credential-verifications
  { credential-holder: principal, credential-type: uint }
  {
    verification-id: uint,
    verification-level: uint,
    verified-date: uint,
    expiration-date: uint,
    status: uint,
    last-updated: uint
  }
)

(define-map verifier-profiles
  { verifier: principal }
  {
    name: (string-ascii 100),
    organization: (string-ascii 100),
    authorized: bool,
    specializations: (list 10 uint),
    verification-count: uint,
    reputation-score: uint,
    authorization-date: uint
  }
)

(define-map verification-audit-trail
  { verification-id: uint, step: uint }
  {
    timestamp: uint,
    action: uint, ;; 1=submitted, 2=reviewed, 3=approved, 4=rejected, 5=renewed
    actor: principal,
    notes: (optional (string-ascii 256))
  }
)

(define-map verification-statistics
  { metric-type: uint } ;; 1=total-requests, 2=approved, 3=rejected, 4=pending
  { count: uint }
)

(define-map credential-type-requirements
  { credential-type: uint }
  {
    minimum-verification-level: uint,
    required-documents: (list 10 (string-ascii 50)),
    validity-period: uint, ;; in blocks
    renewal-grace-period: uint,
    active: bool
  }
)

;; Public Functions

;; Submit verification request
(define-public (submit-verification-request
  (credential-type uint)
  (verification-level uint)
  (verification-data (string-ascii 500))
  (payment uint)
)
  (let (
    (verification-id (var-get next-verification-id))
    (required-fee (get-verification-fee verification-level))
    (current-block stacks-block-height)
    (expiration-date (+ current-block (* u52560 u2))) ;; ~2 years
  )
    (asserts! (var-get verification-enabled) (err u209))
    (asserts! (is-valid-verification-level verification-level) err-invalid-verification-level)
    (asserts! (is-valid-credential-type credential-type) err-invalid-credential-type)
    (asserts! (>= payment required-fee) err-insufficient-fee)
    (asserts! (>= verification-level (var-get minimum-verification-level)) err-invalid-verification-level)
    (asserts! (> (len verification-data) u0) (err u210))
    
    ;; Transfer verification fee
    (try! (stx-transfer? payment tx-sender contract-owner))
    
    ;; Create verification request
    (map-set verification-requests
      { verification-id: verification-id }
      {
        credential-holder: tx-sender,
        credential-type: credential-type,
        verification-level: verification-level,
        status: status-pending,
        requested-date: current-block,
        processed-date: none,
        verifier: none,
        fee-paid: payment,
        expiration-date: expiration-date,
        verification-data: (some verification-data),
        rejection-reason: none
      }
    )
    
    ;; Add audit trail entry
    (add-verification-audit verification-id u0 u1 tx-sender (some "Verification request submitted"))
    
    ;; Update statistics
    (update-verification-stats u1 u1) ;; total-requests
    (update-verification-stats u4 u1) ;; pending
    
    ;; Update contract state
    (var-set next-verification-id (+ verification-id u1))
    (var-set contract-balance (+ (var-get contract-balance) payment))
    (var-set total-verifications (+ (var-get total-verifications) u1))
    
    (ok verification-id)
  )
)

;; Process verification request (verifier only)
(define-public (process-verification
  (verification-id uint)
  (approved bool)
  (notes (optional (string-ascii 256)))
)
  (let (
    (request (unwrap! (map-get? verification-requests { verification-id: verification-id }) err-not-found))
    (verifier-profile (unwrap! (map-get? verifier-profiles { verifier: tx-sender }) err-unauthorized))
    (current-block stacks-block-height)
    (new-status (if approved status-verified status-rejected))
    (action-type (if approved u3 u4))
  )
    (asserts! (get authorized verifier-profile) err-unauthorized)
    (asserts! (is-eq (get status request) status-pending) (err u211))
    (asserts! (can-verify-credential-type tx-sender (get credential-type request)) err-unauthorized)
    
    ;; Update verification request
    (map-set verification-requests
      { verification-id: verification-id }
      (merge request {
        status: new-status,
        processed-date: (some current-block),
        verifier: (some tx-sender),
        rejection-reason: (if approved none notes)
      })
    )
    
    ;; If approved, create credential verification record
    (if approved
      (map-set credential-verifications
        { 
          credential-holder: (get credential-holder request), 
          credential-type: (get credential-type request) 
        }
        {
          verification-id: verification-id,
          verification-level: (get verification-level request),
          verified-date: current-block,
          expiration-date: (get expiration-date request),
          status: status-verified,
          last-updated: current-block
        }
      )
      true
    )
    
    ;; Add audit trail entry
    (add-verification-audit verification-id (get-next-audit-step verification-id) action-type tx-sender notes)
    
    ;; Update verifier statistics
    (update-verifier-stats tx-sender)
    
    ;; Update verification statistics
    (if approved
      (update-verification-stats u2 u1) ;; approved
      (update-verification-stats u3 u1) ;; rejected
    )
    (update-verification-stats u4 u0) ;; pending (decrease by 1)
    
    (ok true)
  )
)

;; Renew credential verification
(define-public (renew-verification
  (credential-type uint)
  (payment uint)
)
  (let (
    (current-verification (unwrap! 
      (map-get? credential-verifications { credential-holder: tx-sender, credential-type: credential-type })
      err-not-found
    ))
    (current-block stacks-block-height)
    (renewal-fee (/ (get-verification-fee (get verification-level current-verification)) u2)) ;; 50% discount for renewal
    (new-expiration (+ current-block (* u52560 u2))) ;; 2 years from now
  )
    (asserts! (var-get verification-enabled) (err u209))
    (asserts! (>= payment renewal-fee) err-insufficient-fee)
    (asserts! (is-eq (get status current-verification) status-verified) (err u212))
    
    ;; Transfer renewal fee
    (try! (stx-transfer? payment tx-sender contract-owner))
    
    ;; Update verification record
    (map-set credential-verifications
      { credential-holder: tx-sender, credential-type: credential-type }
      (merge current-verification {
        expiration-date: new-expiration,
        last-updated: current-block
      })
    )
    
    ;; Add audit trail entry
    (add-verification-audit (get verification-id current-verification) 
                          (get-next-audit-step (get verification-id current-verification)) 
                          u5 
                          tx-sender 
                          (some "Verification renewed"))
    
    ;; Update contract balance
    (var-set contract-balance (+ (var-get contract-balance) payment))
    
    (ok true)
  )
)

;; Register verifier (owner only)
(define-public (register-verifier
  (verifier principal)
  (name (string-ascii 100))
  (organization (string-ascii 100))
  (specializations (list 10 uint))
)
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (asserts! (is-none (map-get? verifier-profiles { verifier: verifier })) err-already-exists)
    (asserts! (> (len name) u0) (err u213))
    (asserts! (> (len organization) u0) (err u214))
    (asserts! (> (len specializations) u0) (err u215))
    
    (map-set verifier-profiles
      { verifier: verifier }
      {
        name: name,
        organization: organization,
        authorized: true,
        specializations: specializations,
        verification-count: u0,
        reputation-score: u100,
        authorization-date: stacks-block-height
      }
    )
    
    (ok true)
  )
)

;; Set credential type requirements (owner only)
(define-public (set-credential-requirements
  (credential-type uint)
  (min-verification-level uint)
  (required-docs (list 10 (string-ascii 50)))
  (validity-period uint)
  (grace-period uint)
)
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (asserts! (is-valid-credential-type credential-type) err-invalid-credential-type)
    (asserts! (is-valid-verification-level min-verification-level) err-invalid-verification-level)
    (asserts! (> validity-period u0) (err u216))
    
    (map-set credential-type-requirements
      { credential-type: credential-type }
      {
        minimum-verification-level: min-verification-level,
        required-documents: required-docs,
        validity-period: validity-period,
        renewal-grace-period: grace-period,
        active: true
      }
    )
    
    (ok true)
  )
)

;; Toggle verification system (owner only)
(define-public (toggle-verification-system)
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (var-set verification-enabled (not (var-get verification-enabled)))
    (ok (var-get verification-enabled))
  )
)

;; Read-Only Functions

;; Get verification request details
(define-read-only (get-verification-request (verification-id uint))
  (map-get? verification-requests { verification-id: verification-id })
)

;; Get credential verification status
(define-read-only (get-credential-verification (credential-holder principal) (credential-type uint))
  (map-get? credential-verifications { credential-holder: credential-holder, credential-type: credential-type })
)

;; Check if credential is verified and valid
(define-read-only (is-credential-verified (credential-holder principal) (credential-type uint))
  (match (map-get? credential-verifications { credential-holder: credential-holder, credential-type: credential-type })
    verification
    (and
      (is-eq (get status verification) status-verified)
      (> (get expiration-date verification) stacks-block-height)
    )
    false
  )
)

;; Get verifier profile
(define-read-only (get-verifier-profile (verifier principal))
  (map-get? verifier-profiles { verifier: verifier })
)

;; Get verification fee for level
(define-read-only (get-verification-fee (verification-level uint))
  (if (is-eq verification-level verification-level-basic)
    basic-verification-fee
    (if (is-eq verification-level verification-level-standard)
      standard-verification-fee
      (if (is-eq verification-level verification-level-premium)
        premium-verification-fee
        (if (is-eq verification-level verification-level-enhanced)
          enhanced-verification-fee
          u0
        )
      )
    )
  )
)

;; Get credential type requirements
(define-read-only (get-credential-requirements (credential-type uint))
  (map-get? credential-type-requirements { credential-type: credential-type })
)

;; Get verification audit trail
(define-read-only (get-verification-audit (verification-id uint) (step uint))
  (map-get? verification-audit-trail { verification-id: verification-id, step: step })
)

;; Get verification statistics
(define-read-only (get-verification-stats (metric-type uint))
  (map-get? verification-statistics { metric-type: metric-type })
)

;; Get contract information
(define-read-only (get-contract-info)
  {
    total-verifications: (var-get total-verifications),
    contract-balance: (var-get contract-balance),
    verification-enabled: (var-get verification-enabled),
    minimum-verification-level: (var-get minimum-verification-level),
    contract-owner: contract-owner
  }
)

;; Private Functions

;; Validate verification level
(define-private (is-valid-verification-level (level uint))
  (and (>= level u1) (<= level u4))
)

;; Validate credential type (same as in medical-credentials contract)
(define-private (is-valid-credential-type (credential-type uint))
  (and (>= credential-type u1) (<= credential-type u6))
)

;; Check if verifier can verify specific credential type
(define-private (can-verify-credential-type (verifier principal) (credential-type uint))
  (match (map-get? verifier-profiles { verifier: verifier })
    profile
    (let (
      (specializations (get specializations profile))
    )
      (or
        (is-some (index-of specializations credential-type))
        (is-some (index-of specializations u0)) ;; u0 = all types
      )
    )
    false
  )
)

;; Add verification audit trail entry
(define-private (add-verification-audit
  (verification-id uint)
  (step uint)
  (action uint)
  (actor principal)
  (notes (optional (string-ascii 256)))
)
  (map-set verification-audit-trail
    { verification-id: verification-id, step: step }
    {
      timestamp: stacks-block-height,
      action: action,
      actor: actor,
      notes: notes
    }
  )
)

;; Get next audit step number
(define-private (get-next-audit-step (verification-id uint))
  (let (
    (current-step u0)
  )
    ;; Simple implementation - in production would track step count
    (+ current-step u1)
  )
)

;; Update verification statistics
(define-private (update-verification-stats (metric-type uint) (change uint))
  (let (
    (current-count (default-to u0 (get count (map-get? verification-statistics { metric-type: metric-type }))))
  )
    (map-set verification-statistics
      { metric-type: metric-type }
      { count: (+ current-count change) }
    )
  )
)

;; Update verifier statistics
(define-private (update-verifier-stats (verifier principal))
  (let (
    (current-profile (unwrap! (map-get? verifier-profiles { verifier: verifier }) false))
  )
    (map-set verifier-profiles
      { verifier: verifier }
      (merge current-profile {
        verification-count: (+ (get verification-count current-profile) u1)
      })
    )
    true
  )
)
