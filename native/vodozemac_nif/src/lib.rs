// use std::collections::HashMap;
use std::sync::Mutex;

use rustler::Binary;
use rustler::Env;
use rustler::NifMap;
use rustler::Resource;
use rustler::ResourceArc;
use rustler::Term;

use vodozemac::olm::Account;
use vodozemac::olm::DecryptionError;
use vodozemac::olm::PreKeyMessage;
use vodozemac::olm::SessionConfig;
use vodozemac::olm::SessionCreationError;
use vodozemac::Curve25519PublicKey;

mod atoms {
    rustler::atoms! {
        ok,
        error,
        normal,
        prekey,
        missing_one_time_key,
        mismatched_identity_key,
        mismatched_session_config,
        invalid_mac,
        invalid_mac_length,
        invalid_padding,
        missing_message_key,
        non_contributor_key,
        too_big_message_gap,
        invalid_signature,
        unknown_message_index,
        invalid_message
    }
}

#[derive(NifMap)]
pub struct IdentityKeys {
    pub ed25519: String,
    pub curve25519: String,
}

struct OlmAccountResource {
    pub account: Mutex<Account>,
}

#[rustler::resource_impl]
impl Resource for OlmAccountResource {}

struct OlmSessionResource {
    pub session: Mutex<vodozemac::olm::Session>,
}

#[rustler::resource_impl]
impl Resource for OlmSessionResource {}

struct GroupSessionResource {
    pub group_session: Mutex<vodozemac::megolm::GroupSession>,
}

#[rustler::resource_impl]
impl Resource for GroupSessionResource {}

struct InboundGroupSessionResource {
    pub inbound_group_session: Mutex<vodozemac::megolm::InboundGroupSession>,
}

#[rustler::resource_impl]
impl Resource for InboundGroupSessionResource {}

#[rustler::nif]
pub fn create_account() -> ResourceArc<OlmAccountResource> {
    let account = Account::new();
    ResourceArc::new(OlmAccountResource {
        account: Mutex::new(account),
    })
}

#[derive(NifMap)]
pub struct OneTimeKeys {
    pub created: Vec<String>,
    pub removed: Vec<String>,
}

#[rustler::nif]
pub fn generate_one_time_keys(res: ResourceArc<OlmAccountResource>, count: usize) -> OneTimeKeys {
    let mut account = res.account.lock().unwrap();

    let result = account.generate_one_time_keys(count);

    OneTimeKeys {
        created: result.created.iter().map(|k| k.to_base64()).collect(),
        removed: result.removed.iter().map(|k| k.to_base64()).collect(),
    }
}

#[rustler::nif]
pub fn identity_keys(res: ResourceArc<OlmAccountResource>) -> IdentityKeys {
    let account = res.account.lock().unwrap();
    let keys = account.identity_keys();
    IdentityKeys {
        ed25519: keys.ed25519.to_base64(),
        curve25519: keys.curve25519.to_base64(),
    }
}

#[rustler::nif]
pub fn mark_keys_as_published(res: ResourceArc<OlmAccountResource>) -> rustler::Atom {
    let mut account = res.account.lock().unwrap();
    account.mark_keys_as_published();
    atoms::ok()
}

#[rustler::nif]
pub fn sign(res: ResourceArc<OlmAccountResource>, message: Binary) -> String {
    let account = res.account.lock().unwrap();
    let signed = account.sign(message.as_slice());
    signed.to_base64()
}

#[rustler::nif]
pub fn one_time_keys(
    res: ResourceArc<OlmAccountResource>,
) -> std::collections::HashMap<String, String> {
    let account = res.account.lock().unwrap();
    account
        .one_time_keys()
        .iter()
        .map(|(key_id, public_key)| (key_id.to_base64(), public_key.to_base64()))
        .collect()
}

#[rustler::nif]
pub fn pickle(res: ResourceArc<OlmAccountResource>) -> String {
    let account = res.account.lock().unwrap();
    let pickle = account.pickle();
    serde_json::to_string(&pickle).unwrap()
}

#[rustler::nif]
pub fn unpickle(bytes: String) -> ResourceArc<OlmAccountResource> {
    let pickle: vodozemac::olm::AccountPickle = serde_json::from_str(&bytes).unwrap();

    let account = Account::from_pickle(pickle);
    ResourceArc::new(OlmAccountResource {
        account: Mutex::new(account),
    })
}

// OLM

#[rustler::nif]
pub fn create_outbound_session(
    res: ResourceArc<OlmAccountResource>,
    public_key: String,
    one_time_key: String,
) -> Result<ResourceArc<OlmSessionResource>, rustler::Atom> {
    let identity_key = vodozemac::Curve25519PublicKey::from_base64(public_key.as_str())
        .map_err(|_| atoms::invalid_message())?;
    let one_time_key = vodozemac::Curve25519PublicKey::from_base64(one_time_key.as_str())
        .map_err(|_| atoms::invalid_message())?;

    let account = res.account.lock().unwrap();
    let session = account
        .create_outbound_session(
            vodozemac::olm::SessionConfig::default(),
            identity_key,
            one_time_key,
        )
        .map_err(|_| atoms::invalid_message())?;

    Ok(ResourceArc::new(OlmSessionResource {
        session: Mutex::new(session),
    }))
}

enum CreateInboundSessionError {
    Creation(SessionCreationError),
    InvalidMessage,
}

impl rustler::Encoder for CreateInboundSessionError {
    fn encode<'a>(&self, env: Env<'a>) -> Term<'a> {
        let error = match self {
            CreateInboundSessionError::Creation(error) => error,
            CreateInboundSessionError::InvalidMessage => {
                return atoms::invalid_message().encode(env)
            }
        };

        match error {
            SessionCreationError::MissingOneTimeKey(key) => {
                (atoms::missing_one_time_key(), key.to_base64()).encode(env)
            }

            SessionCreationError::MismatchedIdentityKey(expected, got) => (
                atoms::mismatched_identity_key(),
                expected.to_base64(),
                got.to_base64(),
            )
                .encode(env),
            SessionCreationError::MismatchedSessionConfig { expected, got: _ } => {
                (atoms::mismatched_session_config(), expected.version()).encode(env)
            }
            SessionCreationError::NonContributoryKey {} => atoms::non_contributor_key().encode(env),
            SessionCreationError::Decryption(e) => match e {
                DecryptionError::InvalidMAC(..) => atoms::invalid_mac().encode(env),
                DecryptionError::InvalidMACLength(expected, got) => {
                    (atoms::invalid_mac_length(), expected, got).encode(env)
                }
                DecryptionError::InvalidPadding(_) => atoms::invalid_padding().encode(env),
                DecryptionError::MissingMessageKey(key) => {
                    (atoms::missing_message_key(), key).encode(env)
                }
                DecryptionError::NonContributoryKey {} => atoms::non_contributor_key().encode(env),
                DecryptionError::TooBigMessageGap(expected, got) => {
                    (atoms::too_big_message_gap(), expected, got).encode(env)
                }
            },
        }
    }
}

#[rustler::nif]
pub fn create_inbound_session(
    res: ResourceArc<OlmAccountResource>,
    public_key: String,
    pre_key_message: String,
) -> Result<(String, ResourceArc<OlmSessionResource>), CreateInboundSessionError> {
    let public_key = Curve25519PublicKey::from_base64(public_key.as_str())
        .map_err(|_| CreateInboundSessionError::InvalidMessage)?;
    let message = PreKeyMessage::from_base64(pre_key_message.as_str())
        .map_err(|_| CreateInboundSessionError::InvalidMessage)?;

    let mut account = res.account.lock().unwrap();
    let inbound_session = account
        .create_inbound_session(SessionConfig::default(), public_key, &message)
        .map_err(CreateInboundSessionError::Creation)?;

    let plaintext = String::from_utf8(inbound_session.plaintext)
        .map_err(|_| CreateInboundSessionError::InvalidMessage)?;
    let session_res = ResourceArc::new(OlmSessionResource {
        session: Mutex::new(inbound_session.session),
    });

    Ok((plaintext, session_res))
}

#[rustler::nif]
pub fn session_id(res: ResourceArc<OlmSessionResource>) -> String {
    let session = &res.session.lock().unwrap();
    session.session_id()
}

#[derive(NifMap)]
pub struct SessionKeys {
    identity_key: String,
    base_key: String,
    one_time_key: String,
}

#[rustler::nif]
pub fn session_keys(res: ResourceArc<OlmSessionResource>) -> SessionKeys {
    let session = &res.session.lock().unwrap();
    let keys = session.session_keys();
    SessionKeys {
        identity_key: keys.identity_key.to_base64(),
        base_key: keys.base_key.to_base64(),
        one_time_key: keys.one_time_key.to_base64(),
    }
}

#[rustler::nif]
pub fn encrypt(res: ResourceArc<OlmSessionResource>, plaintext: String) -> (usize, String) {
    let session = &mut res.session.lock().unwrap();
    let message = session.encrypt(plaintext).unwrap();
    match message {
        vodozemac::olm::OlmMessage::PreKey(msg) => (0, msg.to_base64()),
        vodozemac::olm::OlmMessage::Normal(msg) => (1, msg.to_base64()),
    }
}

enum DecryptError {
    Decryption(DecryptionError),
    InvalidMessage,
}
impl rustler::Encoder for DecryptError {
    fn encode<'a>(&self, env: Env<'a>) -> Term<'a> {
        let error = match self {
            DecryptError::Decryption(error) => error,
            DecryptError::InvalidMessage => return atoms::invalid_message().encode(env),
        };

        match error {
            DecryptionError::InvalidMAC(..) => atoms::invalid_mac().encode(env),
            DecryptionError::InvalidMACLength(expected, got) => {
                (atoms::invalid_mac_length(), expected, got).encode(env)
            }
            DecryptionError::InvalidPadding(_) => atoms::invalid_padding().encode(env),
            DecryptionError::NonContributoryKey {} => atoms::non_contributor_key().encode(env),
            DecryptionError::MissingMessageKey(key) => {
                (atoms::missing_message_key(), key).encode(env)
            }
            DecryptionError::TooBigMessageGap(expected, got) => {
                (atoms::too_big_message_gap(), expected, got).encode(env)
            }
        }
    }
}

#[rustler::nif]
pub fn decrypt(
    res: ResourceArc<OlmSessionResource>,
    message_type: usize,
    ciphertext: String,
) -> Result<String, DecryptError> {
    let decoded =
        vodozemac::base64_decode(ciphertext).map_err(|_| DecryptError::InvalidMessage)?;
    let message = vodozemac::olm::OlmMessage::from_parts(message_type, &decoded)
        .map_err(|_| DecryptError::InvalidMessage)?;

    let mut session = res.session.lock().unwrap();
    let decrypted = session.decrypt(&message).map_err(DecryptError::Decryption)?;
    String::from_utf8(decrypted).map_err(|_| DecryptError::InvalidMessage)
}

#[rustler::nif]
pub fn pickle_session(res: ResourceArc<OlmSessionResource>) -> String {
    let session = &res.session.lock().unwrap();
    let pickle = session.pickle();
    serde_json::to_string(&pickle).unwrap()
}

#[rustler::nif]
pub fn unpickle_session(bytes: String) -> ResourceArc<OlmSessionResource> {
    let pickle: vodozemac::olm::SessionPickle = serde_json::from_str(&bytes).unwrap();

    let session = vodozemac::olm::Session::from_pickle(pickle);
    ResourceArc::new(OlmSessionResource {
        session: Mutex::new(session),
    })
}

// MEGAOLM

#[rustler::nif]
pub fn create_group_session() -> ResourceArc<GroupSessionResource> {
    let group_session =
        vodozemac::megolm::GroupSession::new(vodozemac::megolm::SessionConfig::default());
    ResourceArc::new(GroupSessionResource {
        group_session: Mutex::new(group_session),
    })
}

#[rustler::nif]
pub fn group_session_id(res: ResourceArc<GroupSessionResource>) -> String {
    let group_session = res.group_session.lock().unwrap();
    group_session.session_id()
}

#[rustler::nif]
pub fn group_session_key(res: ResourceArc<GroupSessionResource>) -> String {
    let group_session = res.group_session.lock().unwrap();
    group_session.session_key().to_base64()
}

#[rustler::nif]
pub fn group_session_encrypt(res: ResourceArc<GroupSessionResource>, plaintext: String) -> String {
    let mut group_session = res.group_session.lock().unwrap();
    let megolm_message = group_session.encrypt(plaintext);
    megolm_message.to_base64()
}

#[rustler::nif]
pub fn pickle_group_session(res: ResourceArc<GroupSessionResource>) -> String {
    let group_session = res.group_session.lock().unwrap();
    let pickle = group_session.pickle();
    serde_json::to_string(&pickle).unwrap()
}

#[rustler::nif]
pub fn unpickle_group_session(bytes: String) -> ResourceArc<GroupSessionResource> {
    let pickle: vodozemac::megolm::GroupSessionPickle = serde_json::from_str(&bytes).unwrap();
    let group_session = vodozemac::megolm::GroupSession::from_pickle(pickle);
    ResourceArc::new(GroupSessionResource {
        group_session: Mutex::new(group_session),
    })
}

#[rustler::nif]
pub fn create_inbound_group_session(
    session_key_string: String,
) -> Result<ResourceArc<InboundGroupSessionResource>, rustler::Atom> {
    let session_key = vodozemac::megolm::SessionKey::from_base64(&session_key_string)
        .map_err(|_| atoms::invalid_message())?;
    let inbound_group_session = vodozemac::megolm::InboundGroupSession::new(
        &session_key,
        vodozemac::megolm::SessionConfig::default(),
    );
    Ok(ResourceArc::new(InboundGroupSessionResource {
        inbound_group_session: Mutex::new(inbound_group_session),
    }))
}

#[rustler::nif]
pub fn import_inbound_group_session(
    exported_key_string: String,
) -> Result<ResourceArc<InboundGroupSessionResource>, rustler::Atom> {
    let exported_key = vodozemac::megolm::ExportedSessionKey::from_base64(&exported_key_string)
        .map_err(|_| atoms::invalid_message())?;
    let inbound_group_session = vodozemac::megolm::InboundGroupSession::import(
        &exported_key,
        vodozemac::megolm::SessionConfig::default(),
    );
    Ok(ResourceArc::new(InboundGroupSessionResource {
        inbound_group_session: Mutex::new(inbound_group_session),
    }))
}

#[rustler::nif]
pub fn export_inbound_group_session(res: ResourceArc<InboundGroupSessionResource>) -> String {
    let mut session = res.inbound_group_session.lock().unwrap();
    let index = session.first_known_index();
    session
        .export_at(index)
        .expect("the first known index is always exportable")
        .to_base64()
}

#[rustler::nif]
pub fn inbound_group_session_id(res: ResourceArc<InboundGroupSessionResource>) -> String {
    let inbound_group_session = res.inbound_group_session.lock().unwrap();
    inbound_group_session.session_id()
}

#[derive(NifMap)]
pub struct MegOLMDecryptedMessage {
    plaintext: String,
    message_index: u32,
}

// struct InboundGroupSessionDecryptError(vodozemac::megolm::DecryptionError);
enum InboundGroupSessionDecryptError {
    InvalidSignature,
    InvalidMAC,
    InvalidMACLength(usize, usize),
    InvalidPadding,
    UnknownMessageIndex(u32, u32),
    InvalidMessage,
}

impl rustler::Encoder for InboundGroupSessionDecryptError {
    fn encode<'a>(&self, env: Env<'a>) -> Term<'a> {
        match &self {
            InboundGroupSessionDecryptError::InvalidMessage => atoms::invalid_message().encode(env),
            InboundGroupSessionDecryptError::InvalidMAC => atoms::invalid_mac().encode(env),
            InboundGroupSessionDecryptError::InvalidMACLength(expected, got) => {
                (atoms::invalid_mac_length(), expected, got).encode(env)
            }
            InboundGroupSessionDecryptError::InvalidPadding => atoms::invalid_padding().encode(env),
            InboundGroupSessionDecryptError::UnknownMessageIndex(known, index) => {
                (atoms::unknown_message_index(), (known, index)).encode(env)
            }
            InboundGroupSessionDecryptError::InvalidSignature => {
                atoms::invalid_signature().encode(env)
            }
        }
    }
}

#[rustler::nif]
pub fn decrypt_inbound_group_session_message(
    res: ResourceArc<InboundGroupSessionResource>,
    ciphertext: String,
) -> Result<MegOLMDecryptedMessage, InboundGroupSessionDecryptError> {
    // ciphertext is remote input: parse before locking so a failure can't poison the mutex
    let megolm_message = vodozemac::megolm::MegolmMessage::from_base64(&ciphertext)
        .map_err(|_| InboundGroupSessionDecryptError::InvalidMessage)?;
    let mut inbound_group_session = res.inbound_group_session.lock().unwrap();
    let decrypted = inbound_group_session
        .decrypt(&megolm_message)
        .map_err(|e| match e {
            vodozemac::megolm::DecryptionError::Signature(_) => {
                InboundGroupSessionDecryptError::InvalidSignature
            }

            vodozemac::megolm::DecryptionError::InvalidMAC(..) => {
                InboundGroupSessionDecryptError::InvalidMAC
            }

            vodozemac::megolm::DecryptionError::InvalidMACLength(expected, got) => {
                InboundGroupSessionDecryptError::InvalidMACLength(expected, got)
            }

            vodozemac::megolm::DecryptionError::InvalidPadding(_) => {
                InboundGroupSessionDecryptError::InvalidPadding
            }

            vodozemac::megolm::DecryptionError::UnknownMessageIndex(known, index) => {
                InboundGroupSessionDecryptError::UnknownMessageIndex(known, index)
            }
        })?;
    let plaintext = String::from_utf8(decrypted.plaintext)
        .map_err(|_| InboundGroupSessionDecryptError::InvalidMessage)?;
    Ok(MegOLMDecryptedMessage {
        plaintext,
        message_index: decrypted.message_index,
    })
}

#[rustler::nif]
pub fn pickle_inbound_group_session(res: ResourceArc<InboundGroupSessionResource>) -> String {
    let inbound_group_session = res.inbound_group_session.lock().unwrap();
    let pickle = inbound_group_session.pickle();
    serde_json::to_string(&pickle).unwrap()
}

#[rustler::nif]
pub fn unpickle_inbound_group_session(bytes: String) -> ResourceArc<InboundGroupSessionResource> {
    let pickle: vodozemac::megolm::InboundGroupSessionPickle =
        serde_json::from_str(&bytes).unwrap();
    let inbound_group_session = vodozemac::megolm::InboundGroupSession::from_pickle(pickle);
    ResourceArc::new(InboundGroupSessionResource {
        inbound_group_session: Mutex::new(inbound_group_session),
    })
}

rustler::init!("Elixir.Vodozemac");
