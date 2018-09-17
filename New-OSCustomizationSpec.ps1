#create OSCustomizationSpec for domain join
New-OSCustomizationSpec -Name "domain.local" -OSType Windows -Description "This spec adds a computer in a domain." -FullName "domain.local Domain Join" -Domain "domain.local" -DomainUsername "adminusername@domain.local" -DomainPassword "adminpassword" -OrgName "Organization Name" -ChangeSid -Type Persistent
