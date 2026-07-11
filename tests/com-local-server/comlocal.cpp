#include <windows.h>
#include <oleauto.h>

#include <cstdio>
#include <cwchar>
#include <new>
#include <string>

#include "comlocal.h"

namespace {

constexpr wchar_t kClassId[] = L"{125BC02C-583E-4C90-87D5-F5A4298B2B22}";
constexpr wchar_t kCustomProgId[] = L"PHPTest.LocalByRefServer";
constexpr wchar_t kInternetExplorerProgId[] = L"InternetExplorer.Application";
constexpr wchar_t kRegistryRoot[] = L"Software\\Classes\\";
constexpr wchar_t kShutdownEvent[] = L"Local\\PHPComByRefTestServerShutdown";

HRESULT SetRegistryString(const std::wstring& subkey, const wchar_t* value)
{
    HKEY key = nullptr;
    LSTATUS status = RegCreateKeyExW(
        HKEY_CURRENT_USER,
        subkey.c_str(),
        0,
        nullptr,
        REG_OPTION_NON_VOLATILE,
        KEY_SET_VALUE,
        nullptr,
        &key,
        nullptr);
    if (status != ERROR_SUCCESS) {
        return HRESULT_FROM_WIN32(status);
    }

    const DWORD bytes = static_cast<DWORD>((std::wcslen(value) + 1) * sizeof(wchar_t));
    status = RegSetValueExW(key, nullptr, 0, REG_SZ, reinterpret_cast<const BYTE*>(value), bytes);
    RegCloseKey(key);
    return HRESULT_FROM_WIN32(status);
}

HRESULT RegisterProgId(const wchar_t* progId, const wchar_t* description)
{
    const std::wstring key = std::wstring(kRegistryRoot) + progId;
    HRESULT hr = SetRegistryString(key, description);
    if (FAILED(hr)) {
        return hr;
    }
    return SetRegistryString(key + L"\\CLSID", kClassId);
}

HRESULT RegisterServer()
{
    wchar_t modulePath[MAX_PATH];
    const DWORD length = GetModuleFileNameW(nullptr, modulePath, ARRAYSIZE(modulePath));
    if (length == 0 || length == ARRAYSIZE(modulePath)) {
        return HRESULT_FROM_WIN32(GetLastError());
    }

    const std::wstring classKey = std::wstring(kRegistryRoot) + L"CLSID\\" + kClassId;
    HRESULT hr = SetRegistryString(classKey, L"PHP out-of-process COM by-reference test server");
    if (FAILED(hr)) {
        return hr;
    }

    const std::wstring command = L"\"" + std::wstring(modulePath) + L"\" -Embedding";
    hr = SetRegistryString(classKey + L"\\LocalServer32", command.c_str());
    if (FAILED(hr)) {
        return hr;
    }
    hr = SetRegistryString(classKey + L"\\ProgID", kCustomProgId);
    if (FAILED(hr)) {
        return hr;
    }
    hr = SetRegistryString(classKey + L"\\TypeLib", L"{7A450E22-79A2-48B6-B0E2-EA9E4B82910B}");
    if (FAILED(hr)) {
        return hr;
    }
    hr = SetRegistryString(classKey + L"\\Version", L"1.0");
    if (FAILED(hr)) {
        return hr;
    }
    hr = RegisterProgId(kCustomProgId, L"PHP out-of-process COM by-reference test server");
    if (FAILED(hr)) {
        return hr;
    }
    return RegisterProgId(kInternetExplorerProgId, L"PHP replacement for legacy IE COM test automation");
}

void UnregisterServer()
{
    const std::wstring classes = kRegistryRoot;
    RegDeleteTreeW(HKEY_CURRENT_USER, (classes + kInternetExplorerProgId).c_str());
    RegDeleteTreeW(HKEY_CURRENT_USER, (classes + kCustomProgId).c_str());
    RegDeleteTreeW(HKEY_CURRENT_USER, (classes + L"CLSID\\" + kClassId).c_str());
}

HRESULT LoadServerTypeInfo(ITypeInfo** typeInfo)
{
    *typeInfo = nullptr;
    wchar_t modulePath[MAX_PATH];
    const DWORD length = GetModuleFileNameW(nullptr, modulePath, ARRAYSIZE(modulePath));
    if (length == 0 || length == ARRAYSIZE(modulePath)) {
        return HRESULT_FROM_WIN32(GetLastError());
    }

    std::wstring typeLibPath(modulePath);
    const std::wstring::size_type separator = typeLibPath.find_last_of(L"\\/");
    typeLibPath.replace(separator == std::wstring::npos ? 0 : separator + 1, std::wstring::npos, L"comlocal.tlb");

    ITypeLib* typeLib = nullptr;
    HRESULT hr = LoadTypeLibEx(typeLibPath.c_str(), REGKIND_NONE, &typeLib);
    if (FAILED(hr)) {
        return hr;
    }
    hr = typeLib->GetTypeInfoOfGuid(IID_IByRefTest, typeInfo);
    typeLib->Release();
    return hr;
}

class ByRefTest final : public IByRefTest
{
public:
    ByRefTest() : referenceCount_(1), typeInfo_(nullptr) {}

    ~ByRefTest()
    {
        if (typeInfo_ != nullptr) {
            typeInfo_->Release();
        }
    }

    HRESULT Initialize()
    {
        return LoadServerTypeInfo(&typeInfo_);
    }

    STDMETHODIMP QueryInterface(REFIID iid, void** object) override
    {
        if (object == nullptr) {
            return E_POINTER;
        }
        *object = nullptr;
        if (IsEqualIID(iid, IID_IUnknown) || IsEqualIID(iid, IID_IDispatch) || IsEqualIID(iid, IID_IByRefTest)) {
            *object = static_cast<IByRefTest*>(this);
            AddRef();
            return S_OK;
        }
        return E_NOINTERFACE;
    }

    STDMETHODIMP_(ULONG) AddRef() override
    {
        return static_cast<ULONG>(InterlockedIncrement(&referenceCount_));
    }

    STDMETHODIMP_(ULONG) Release() override
    {
        const ULONG count = static_cast<ULONG>(InterlockedDecrement(&referenceCount_));
        if (count == 0) {
            delete this;
        }
        return count;
    }

    STDMETHODIMP GetTypeInfoCount(UINT* count) override
    {
        if (count == nullptr) {
            return E_POINTER;
        }
        *count = 1;
        return S_OK;
    }

    STDMETHODIMP GetTypeInfo(UINT index, LCID, ITypeInfo** typeInfo) override
    {
        if (typeInfo == nullptr) {
            return E_POINTER;
        }
        *typeInfo = nullptr;
        if (index != 0) {
            return DISP_E_BADINDEX;
        }
        typeInfo_->AddRef();
        *typeInfo = typeInfo_;
        return S_OK;
    }

    STDMETHODIMP GetIDsOfNames(REFIID iid, LPOLESTR* names, UINT count, LCID, DISPID* dispIds) override
    {
        if (!IsEqualIID(iid, IID_NULL)) {
            return DISP_E_UNKNOWNINTERFACE;
        }
        return DispGetIDsOfNames(typeInfo_, names, count, dispIds);
    }

    STDMETHODIMP Invoke(
        DISPID member,
        REFIID iid,
        LCID,
        WORD flags,
        DISPPARAMS* parameters,
        VARIANT* result,
        EXCEPINFO* exception,
        UINT* argumentError) override
    {
        if (!IsEqualIID(iid, IID_NULL)) {
            return DISP_E_UNKNOWNINTERFACE;
        }
        return DispInvoke(this, typeInfo_, member, flags, parameters, result, exception, argumentError);
    }

    STDMETHODIMP ClientToWindow(LONG* x, LONG* y) override
    {
        if (x == nullptr || y == nullptr) {
            return E_POINTER;
        }
        *x = 1024;
        *y = 768;
        return S_OK;
    }

    STDMETHODIMP Quit() override
    {
        // Keep the shared local server alive across the PHPT's SKIPIF and FILE
        // processes. The workflow shuts it down explicitly after the test run.
        return S_OK;
    }

private:
    volatile LONG referenceCount_;
    ITypeInfo* typeInfo_;
};

class ByRefTestFactory final : public IClassFactory
{
public:
    ByRefTestFactory() : referenceCount_(1) {}

    STDMETHODIMP QueryInterface(REFIID iid, void** object) override
    {
        if (object == nullptr) {
            return E_POINTER;
        }
        *object = nullptr;
        if (IsEqualIID(iid, IID_IUnknown) || IsEqualIID(iid, IID_IClassFactory)) {
            *object = static_cast<IClassFactory*>(this);
            AddRef();
            return S_OK;
        }
        return E_NOINTERFACE;
    }

    STDMETHODIMP_(ULONG) AddRef() override
    {
        return static_cast<ULONG>(InterlockedIncrement(&referenceCount_));
    }

    STDMETHODIMP_(ULONG) Release() override
    {
        const ULONG count = static_cast<ULONG>(InterlockedDecrement(&referenceCount_));
        if (count == 0) {
            delete this;
        }
        return count;
    }

    STDMETHODIMP CreateInstance(IUnknown* outer, REFIID iid, void** object) override
    {
        if (outer != nullptr) {
            return CLASS_E_NOAGGREGATION;
        }

        ByRefTest* instance = new (std::nothrow) ByRefTest();
        if (instance == nullptr) {
            return E_OUTOFMEMORY;
        }
        HRESULT hr = instance->Initialize();
        if (SUCCEEDED(hr)) {
            hr = instance->QueryInterface(iid, object);
        }
        instance->Release();
        return hr;
    }

    STDMETHODIMP LockServer(BOOL) override
    {
        return S_OK;
    }

private:
    volatile LONG referenceCount_;
};

HRESULT RunServer()
{
    HRESULT hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    if (FAILED(hr)) {
        return hr;
    }

    HANDLE shutdown = CreateEventW(nullptr, TRUE, FALSE, kShutdownEvent);
    if (shutdown == nullptr) {
        hr = HRESULT_FROM_WIN32(GetLastError());
        CoUninitialize();
        return hr;
    }

    ByRefTestFactory* factory = new (std::nothrow) ByRefTestFactory();
    if (factory == nullptr) {
        CloseHandle(shutdown);
        CoUninitialize();
        return E_OUTOFMEMORY;
    }

    DWORD registration = 0;
    hr = CoRegisterClassObject(
        CLSID_ByRefTest,
        factory,
        CLSCTX_LOCAL_SERVER,
        REGCLS_MULTIPLEUSE,
        &registration);
    factory->Release();
    if (SUCCEEDED(hr)) {
        WaitForSingleObject(shutdown, INFINITE);
        CoRevokeClassObject(registration);
    }

    CloseHandle(shutdown);
    CoUninitialize();
    return hr;
}

HRESULT ShutdownServer()
{
    HANDLE shutdown = OpenEventW(EVENT_MODIFY_STATE, FALSE, kShutdownEvent);
    if (shutdown == nullptr) {
        return HRESULT_FROM_WIN32(GetLastError());
    }
    const BOOL signaled = SetEvent(shutdown);
    const DWORD error = signaled ? ERROR_SUCCESS : GetLastError();
    CloseHandle(shutdown);
    return HRESULT_FROM_WIN32(error);
}

} // namespace

int wmain(int argc, wchar_t** argv)
{
    HRESULT hr;
    if (argc > 1 && (_wcsicmp(argv[1], L"/RegServer") == 0 || _wcsicmp(argv[1], L"-RegServer") == 0)) {
        hr = RegisterServer();
    } else if (argc > 1 && (_wcsicmp(argv[1], L"/UnregServer") == 0 || _wcsicmp(argv[1], L"-UnregServer") == 0)) {
        UnregisterServer();
        hr = S_OK;
    } else if (argc > 1 && (_wcsicmp(argv[1], L"/Shutdown") == 0 || _wcsicmp(argv[1], L"-Shutdown") == 0)) {
        hr = ShutdownServer();
    } else {
        hr = RunServer();
    }

    if (FAILED(hr)) {
        fwprintf(stderr, L"comlocal failed: 0x%08lX\n", static_cast<unsigned long>(hr));
        return 1;
    }
    return 0;
}
