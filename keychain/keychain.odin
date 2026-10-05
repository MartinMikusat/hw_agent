package keychain

// Generic-password items in the login Keychain via Security.framework.
// Service "hw_agent", one account per secret.

import CF "core:sys/darwin/CoreFoundation"
import "core:strings"
import devlog "devlog:."

foreign import security "system:Security.framework"
foreign import corefoundation "system:CoreFoundation.framework"

SERVICE :: "hw_agent"

@(private)
Dictionary_Callbacks :: struct {
	version, retain, release, copy_description, equal, hash: rawptr,
}

@(default_calling_convention = "c")
foreign corefoundation {
	kCFTypeDictionaryKeyCallBacks:   Dictionary_Callbacks
	kCFTypeDictionaryValueCallBacks: Dictionary_Callbacks
	kCFBooleanTrue:                  CF.TypeRef
	CFDictionaryCreate :: proc(allocator: rawptr, keys, values: [^]CF.TypeRef, count: CF.Index, key_cb, value_cb: ^Dictionary_Callbacks) -> CF.TypeRef ---
	CFStringCreateWithBytes :: proc(allocator: rawptr, bytes: [^]u8, length: CF.Index, encoding: u32, is_external: b8) -> CF.TypeRef ---
	CFDataCreate :: proc(allocator: rawptr, bytes: [^]u8, length: CF.Index) -> CF.TypeRef ---
	CFDataGetBytePtr :: proc(data: CF.TypeRef) -> [^]u8 ---
	CFDataGetLength :: proc(data: CF.TypeRef) -> CF.Index ---
}

@(default_calling_convention = "c")
foreign security {
	kSecClass:                CF.TypeRef
	kSecClassGenericPassword: CF.TypeRef
	kSecAttrService:          CF.TypeRef
	kSecAttrAccount:          CF.TypeRef
	kSecValueData:            CF.TypeRef
	kSecReturnData:           CF.TypeRef
	kSecMatchLimit:           CF.TypeRef
	kSecMatchLimitOne:        CF.TypeRef
	SecItemCopyMatching :: proc(query: CF.TypeRef, result: ^CF.TypeRef) -> i32 ---
	SecItemAdd :: proc(attributes: CF.TypeRef, result: ^CF.TypeRef) -> i32 ---
	SecItemUpdate :: proc(query, attributes_to_update: CF.TypeRef) -> i32 ---
}

ERR_ITEM_NOT_FOUND :: -25300

@(private)
dict :: proc(keys, values: []CF.TypeRef) -> CF.TypeRef {
	assert(len(keys) == len(values))
	return CFDictionaryCreate(nil, raw_data(keys), raw_data(values), CF.Index(len(keys)), &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks)
}

@(private)
cf_string :: proc(s: string) -> CF.TypeRef {
	return CFStringCreateWithBytes(nil, raw_data(s), CF.Index(len(s)), 0x0800_0100, false) // kCFStringEncodingUTF8
}

// Returns "" when the item is missing or unreadable.
read :: proc(account: string, allocator := context.allocator) -> (string, i32) {
	service := cf_string(SERVICE)
	defer CF.CFRelease(service)
	acct := cf_string(account)
	defer CF.CFRelease(acct)
	query := dict(
		{kSecClass, kSecAttrService, kSecAttrAccount, kSecReturnData, kSecMatchLimit},
		{kSecClassGenericPassword, service, acct, kCFBooleanTrue, kSecMatchLimitOne},
	)
	defer CF.CFRelease(query)
	result: CF.TypeRef
	status := SecItemCopyMatching(query, &result)
	if status != 0 && status != ERR_ITEM_NOT_FOUND {
		devlog.failed(devlog.global(), {feature = "keychain", operation = "read"}, {reason = "keychain item could not be read", code = status})
	}
	if status != 0 || result == nil { return "", status }
	defer CF.CFRelease(result)
	n := int(CFDataGetLength(result))
	return strings.clone(string(CFDataGetBytePtr(result)[:n]), allocator), 0
}

// Add or replace the item.
write :: proc(account, secret: string) -> i32 {
	service := cf_string(SERVICE)
	defer CF.CFRelease(service)
	acct := cf_string(account)
	defer CF.CFRelease(acct)
	data := CFDataCreate(nil, raw_data(secret), CF.Index(len(secret)))
	defer CF.CFRelease(data)
	query := dict({kSecClass, kSecAttrService, kSecAttrAccount}, {kSecClassGenericPassword, service, acct})
	defer CF.CFRelease(query)
	update := dict({kSecValueData}, {data})
	defer CF.CFRelease(update)
	status := SecItemUpdate(query, update)
	if status != ERR_ITEM_NOT_FOUND {
		if status != 0 {
			devlog.failed(devlog.global(), {feature = "keychain", operation = "write"}, {reason = "keychain item could not be written", code = status})
		}
		return status
	}
	attrs := dict(
		{kSecClass, kSecAttrService, kSecAttrAccount, kSecValueData},
		{kSecClassGenericPassword, service, acct, data},
	)
	defer CF.CFRelease(attrs)
	status = SecItemAdd(attrs, nil)
	if status != 0 {
		devlog.failed(devlog.global(), {feature = "keychain", operation = "write"}, {reason = "keychain item could not be written", code = status})
	}
	return status
}
