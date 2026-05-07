use paranoia_lib::ffi::{
    paranoia_free_string, paranoia_last_error, paranoia_qr_confirm_exchange,
    paranoia_qr_create_invitation, paranoia_qr_create_response, paranoia_qr_fingerprint,
};
use serde_json::Value;
use std::ffi::{CStr, CString};

fn cs(s: &str) -> CString {
    CString::new(s).expect("CString::new")
}

fn take_string(ptr: *mut std::os::raw::c_char) -> String {
    assert!(!ptr.is_null(), "FFI returned NULL: {}", last_error());
    let value = unsafe { CStr::from_ptr(ptr) }
        .to_str()
        .expect("utf8")
        .to_string();
    paranoia_free_string(ptr);
    value
}

fn last_error() -> String {
    let ptr = paranoia_last_error();
    if ptr.is_null() {
        return String::new();
    }
    unsafe { CStr::from_ptr(ptr) }
        .to_str()
        .unwrap_or("")
        .to_string()
}

fn json_object_field_json(value: &Value, field: &str) -> String {
    serde_json::to_string(value.get(field).expect(field)).expect("json")
}

#[test]
fn ffi_qr_exchange_requires_fingerprint_confirmation() {
    let invitation_json = take_string(paranoia_qr_create_invitation(
        cs("alice").as_ptr(),
        cs("bob").as_ptr(),
    ));
    let invitation: Value = serde_json::from_str(&invitation_json).expect("invitation json");
    let invitation_state_json = json_object_field_json(&invitation, "state");
    let invitation_payload_json = json_object_field_json(&invitation, "payload");

    let response_json = take_string(paranoia_qr_create_response(
        cs(&invitation_payload_json).as_ptr(),
        cs("bob").as_ptr(),
    ));
    let response: Value = serde_json::from_str(&response_json).expect("response json");
    let response_state_json = json_object_field_json(&response, "state");
    let response_payload_json = json_object_field_json(&response, "payload");

    let alice_fingerprint = take_string(paranoia_qr_fingerprint(
        cs(&invitation_state_json).as_ptr(),
        cs(&response_payload_json).as_ptr(),
    ));
    let bob_fingerprint = take_string(paranoia_qr_fingerprint(
        cs(&response_state_json).as_ptr(),
        cs(&invitation_payload_json).as_ptr(),
    ));

    assert_eq!(alice_fingerprint, bob_fingerprint);
    assert_eq!(alice_fingerprint.len(), 6);

    let rejected = paranoia_qr_confirm_exchange(
        cs(&invitation_state_json).as_ptr(),
        cs(&response_payload_json).as_ptr(),
        cs("000000").as_ptr(),
    );
    assert!(rejected.is_null());
    assert_eq!(last_error(), "fingerprint_mismatch");

    let alice_completed_json = take_string(paranoia_qr_confirm_exchange(
        cs(&invitation_state_json).as_ptr(),
        cs(&response_payload_json).as_ptr(),
        cs(&alice_fingerprint).as_ptr(),
    ));
    let bob_completed_json = take_string(paranoia_qr_confirm_exchange(
        cs(&response_state_json).as_ptr(),
        cs(&invitation_payload_json).as_ptr(),
        cs(&bob_fingerprint).as_ptr(),
    ));
    let alice_completed: Value = serde_json::from_str(&alice_completed_json).expect("completed");
    let bob_completed: Value = serde_json::from_str(&bob_completed_json).expect("completed");

    assert_eq!(
        alice_completed["session_key_b64"],
        bob_completed["session_key_b64"]
    );
    assert_eq!(alice_completed["fingerprint"], bob_completed["fingerprint"]);
}
